import ActivityKit
import AppIntents
import Foundation

// Shared with the widget extension. The intents are compiled into both targets,
// but as LiveActivityIntents they run in the app's process, which owns the data
// and the activities. The widget only needs them to build its buttons.

nonisolated enum AttemptOutcome: String, Codable, CaseIterable {
    case make, close, miss

    var label: String {
        switch self {
        case .make: "Make"
        case .close: "Rimmed out"
        case .miss: "Miss"
        }
    }
}

// MARK: - Workout

/// A workout in progress, on the lock screen.
nonisolated struct WorkoutActivityAttributes: ActivityAttributes, Sendable {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        /// Sets not done yet, in order, capped to keep within the activity's size limit.
        var upcoming: [UpcomingSet]
        var doneSets: Int
        var totalSets: Int

        var current: UpcomingSet? { upcoming.first }

        var nextExercise: String? {
            upcoming.first { $0.exercise != current?.exercise }?.exercise
        }
    }

    nonisolated struct UpcomingSet: Codable, Hashable, Sendable {
        var id: UUID
        var exercise: String
        /// "Set 2 of 4 · each leg"
        var label: String
        /// "4 × 205 lb"
        var summary: String
    }

    /// The log's persistent ID, encoded.
    var logID: String
    var title: String
    var startedAt: Date
}

// MARK: - Practice

/// A dunk practice session in progress, on the lock screen.
nonisolated struct PracticeActivityAttributes: ActivityAttributes, Sendable {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        var stage: String
        var attempts: Int
        var makes: Int
        var cap: Int
        /// Newest last.
        var recent: [AttemptOutcome]
    }

    /// The session's persistent ID, encoded.
    var sessionID: String
    var focus: String
    var startedAt: Date
}

// MARK: - Buttons

struct CompleteSetIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mark set done"
    static let isDiscoverable = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Workout") var logID: String
    @Parameter(title: "Set") var setID: String

    init() {}

    init(logID: String, setID: UUID) {
        self.logID = logID
        self.setID = setID.uuidString
    }

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        if let id = UUID(uuidString: setID) {
            await LiveActivities.completeSet(id, inLog: logID)
        }
        #endif
        return .result()
    }
}

struct RecordAttemptIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Record a dunk attempt"
    static let isDiscoverable = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Session") var sessionID: String
    @Parameter(title: "Outcome") var outcome: String

    init() {}

    init(sessionID: String, outcome: AttemptOutcome) {
        self.sessionID = sessionID
        self.outcome = outcome.rawValue
    }

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        if let outcome = AttemptOutcome(rawValue: outcome) {
            await LiveActivities.record(outcome, inSession: sessionID)
        }
        #endif
        return .result()
    }
}
