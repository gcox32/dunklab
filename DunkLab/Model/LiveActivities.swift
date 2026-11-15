import ActivityKit
import Foundation
import SwiftData

/// Keeps the lock-screen Live Activities in step with the workout or practice
/// session on screen, and applies taps on their buttons.
enum LiveActivities {
    // MARK: Workout

    /// Starts or refreshes the activity for a workout. Only one workout shows at a time.
    static func show(_ log: WorkoutLog) async {
        guard let key = key(for: log) else { return }
        let attributes = WorkoutActivityAttributes(logID: key, title: log.title, startedAt: log.startedAt)
        await present(attributes, state(for: log))
    }

    static func endWorkouts() {
        Task { await end(WorkoutActivityAttributes.self) }
    }

    static func state(for log: WorkoutLog) -> WorkoutActivityAttributes.ContentState {
        let all = log.sortedEntries.flatMap { entry in entry.sets.enumerated().map { (entry, $0.offset, $0.element) } }
        // Capped so the state stays under the 4 KB an activity allows.
        let upcoming = all.filter { !$0.2.done }.prefix(24).map { entry, index, set in
            var label = entry.sets.count > 1 ? "Set \(index + 1) of \(entry.sets.count)" : "One set"
            if let side = entry.perSide { label += " · each \(side)" }
            return WorkoutActivityAttributes.UpcomingSet(
                id: set.id, exercise: entry.exercise.capitalizedSentence, label: label, summary: set.summary)
        }
        return .init(upcoming: Array(upcoming), doneSets: all.filter(\.2.done).count, totalSets: all.count)
    }

    static func completeSet(_ setID: UUID, inLog key: String) async {
        let context = AppStore.container.mainContext
        guard let log: WorkoutLog = model(key, in: context), log.finishedAt == nil else {
            await end(WorkoutActivityAttributes.self)
            return
        }
        for entry in log.entries {
            guard let index = entry.sets.firstIndex(where: { $0.id == setID }) else { continue }
            var sets = entry.sets
            sets[index].done = true
            entry.sets = sets
        }
        await show(log)
    }

    // MARK: Practice

    /// Starts or refreshes the activity for a practice session. Only one shows at a time.
    static func show(_ session: PracticeSession) async {
        guard let key = key(for: session) else { return }
        let attributes = PracticeActivityAttributes(sessionID: key, focus: session.focus, startedAt: session.startedAt)
        await present(attributes, state(for: session))
    }

    static func endPractice() {
        Task { await end(PracticeActivityAttributes.self) }
    }

    static func state(for session: PracticeSession) -> PracticeActivityAttributes.ContentState {
        let attempts = session.sortedAttempts
        return .init(stage: session.stage, attempts: attempts.count, makes: session.makes,
                     cap: session.attemptCap, recent: attempts.suffix(12).map(\.outcome))
    }

    static func record(_ outcome: AttemptOutcome, inSession key: String) async {
        let context = AppStore.container.mainContext
        guard let session: PracticeSession = model(key, in: context), session.finishedAt == nil else {
            await end(PracticeActivityAttributes.self)
            return
        }
        let attempt = DunkAttempt(stage: session.stage, outcome: outcome)
        context.insert(attempt)
        attempt.session = session
        await show(session)
    }

    // MARK: Activities

    /// Updates the activity for the same workout or session, or starts one,
    /// and ends any left over from another.
    private nonisolated static func present<A: KeyedAttributes>(_ attributes: A, _ state: A.ContentState) async {
        let content = ActivityContent(state: state, staleDate: nil)
        let activities = Activity<A>.activities
        // Request before any await, so two quick updates can't both start one.
        if !activities.contains(where: { $0.attributes.key == attributes.key }),
           ActivityAuthorizationInfo().areActivitiesEnabled {
            _ = try? Activity.request(attributes: attributes, content: content)
        }
        for activity in activities {
            if activity.attributes.key == attributes.key {
                await activity.update(content)
            } else {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private static func end<A: ActivityAttributes>(_: A.Type) async {
        for activity in Activity<A>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    // MARK: IDs

    /// Attributes that name the workout or session they belong to.
    nonisolated protocol KeyedAttributes: ActivityAttributes, Sendable where ContentState: Sendable {
        var key: String { get }
    }

    /// A string form of the model's ID for the activity to carry. Saves first,
    /// since a model that was just inserted only has a temporary ID.
    private static func key(for model: some PersistentModel) -> String? {
        guard let context = model.modelContext else { return nil }
        if context.hasChanges { try? context.save() }
        // Sorted, so the same ID gives the same key in every launch of the app.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(model.persistentModelID))?.base64EncodedString()
    }

    private static func model<T: PersistentModel>(_ key: String, in context: ModelContext) -> T? {
        guard let data = Data(base64Encoded: key),
              let id = try? JSONDecoder().decode(PersistentIdentifier.self, from: data) else { return nil }
        if let registered: T = context.registeredModel(for: id) { return registered }
        return try? context.fetch(FetchDescriptor<T>(predicate: #Predicate { $0.persistentModelID == id })).first
    }
}

nonisolated extension WorkoutActivityAttributes: LiveActivities.KeyedAttributes {
    var key: String { logID }
}

nonisolated extension PracticeActivityAttributes: LiveActivities.KeyedAttributes {
    var key: String { sessionID }
}
