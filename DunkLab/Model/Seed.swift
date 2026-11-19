import Foundation
import SwiftData

/// Imports bundled seed files into the store once. After import the content is
/// ordinary user data: editable, deletable, never read from the bundle again.
enum Seed {
    private static let importedKey = "seed.imported.v1"

    static func importIfNeeded(into context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: importedKey) else {
            migrate(context)
            return
        }
        do {
            if let program = try load(ProgramFile.self, named: "phd-program") {
                insert(program, into: context)
            }
            if let practice = try load(PracticeFile.self, named: "practice-defaults") {
                insert(practice, into: context)
            }
            try context.save()
            UserDefaults.standard.set(true, forKey: importedKey)
            UserDefaults.standard.set(true, forKey: restDaysKey)
            UserDefaults.standard.set(true, forKey: videosKey)
            UserDefaults.standard.set(true, forKey: gaugesKey)
            UserDefaults.standard.set(true, forKey: reactiveKey)
            UserDefaults.standard.set(true, forKey: ownedKey)
        } catch {
            assertionFailure("Seed import failed: \(error)")
        }
    }

    // MARK: Updates to data imported by earlier versions

    private static let restDaysKey = "seed.migrated.restDays"
    private static let videosKey = "seed.migrated.videos"
    private static let gaugesKey = "seed.migrated.gauges"
    private static let reactiveKey = "seed.migrated.reactive"
    private static let ownedKey = "seed.migrated.owned"

    /// Rest days arrived after the first import. Fill them in on program days
    /// that predate the field, using the PhD Program's rule: a rest day before
    /// each of the first three workouts of a week, none before the fourth.
    private static func migrate(_ context: ModelContext) {
        migrateRestDays(context)
        migrateVideos(context)
        migrateGauges(context)
        migrateReactive(context)
        migrateOwned(context)
    }

    /// Owning a dunk arrived after landing one. A dunk marked landed with no makes
    /// on record was ticked in onboarding or by hand, so it's one the athlete
    /// already had: mark it owned. One landed from practice makes stays landed
    /// until it's made in enough sessions.
    private static func migrateOwned(_ context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: ownedKey) else { return }
        let stages = (try? context.fetch(FetchDescriptor<DunkStage>())) ?? []
        let attempts = (try? context.fetch(FetchDescriptor<DunkAttempt>())) ?? []
        let made = Set(attempts.filter { $0.outcome == .make }.map(\.stage))
        for stage in stages where stage.landedAt != nil && !made.contains(stage.name) {
            stage.ownedAt = stage.landedAt
        }
        try? context.save()
        UserDefaults.standard.set(true, forKey: ownedKey)
    }

    /// RSI timing arrived after the gauges. Drop jumps, in the program and in
    /// workouts already logged, get the reactive gauge unless they have another.
    private static func migrateReactive(_ context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: reactiveKey) else { return }
        for item in (try? context.fetch(FetchDescriptor<PlanItem>())) ?? []
        where item.gauge == nil && item.exercise.lowercased() == "drop jumps" {
            item.gauge = .reactive
        }
        for entry in (try? context.fetch(FetchDescriptor<LoggedEntry>())) ?? []
        where entry.gaugeRaw == nil && entry.exercise.lowercased() == "drop jumps" {
            entry.gaugeRaw = Gauge.reactive.rawValue
        }
        try? context.save()
        UserDefaults.standard.set(true, forKey: reactiveKey)
    }

    private static func migrateRestDays(_ context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: restDaysKey) else { return }
        let weeks = (try? context.fetch(FetchDescriptor<ProgramWeek>())) ?? []
        for week in weeks {
            for day in week.days { day.restDaysBefore = day.order < 3 ? 1 : 0 }
        }
        try? context.save()
        UserDefaults.standard.set(true, forKey: restDaysKey)
    }

    /// Videos arrived after the first import. Match them to exercises by name,
    /// leaving any video the user has already set alone.
    private static func migrateVideos(_ context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: videosKey) else { return }
        guard let file = try? load(ProgramFile.self, named: "phd-program") else { return }
        var videos: [String: String] = [:]
        for group in file.weeks.flatMap(\.days) + file.asNeeded {
            for item in group.items {
                if let video = item.video { videos[item.exercise.lowercased()] = video }
            }
        }
        let items = (try? context.fetch(FetchDescriptor<PlanItem>())) ?? []
        for item in items {
            if item.videoURL == nil { item.videoURL = videos[item.exercise.lowercased()] }
            // The play button replaces the PDF's "see video" note.
            if item.details == "see video", item.videoURL != nil { item.details = nil }
        }
        try? context.save()
        UserDefaults.standard.set(true, forKey: videosKey)
    }

    /// Max tests, bar-speed checks, swaps, the squat test videos and
    /// per-row videos arrived after the first import. Match program rows by
    /// position and name, so anything the user renamed or moved is left alone.
    private static func migrateGauges(_ context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: gaugesKey) else { return }
        guard let file = try? load(ProgramFile.self, named: "phd-program") else { return }
        let programs = (try? context.fetch(FetchDescriptor<Program>())) ?? []
        guard let program = programs.first(where: { $0.name == file.name }) else {
            UserDefaults.standard.set(true, forKey: gaugesKey)
            return
        }
        if program.basisVideosData == nil { program.basisVideos = file.basisVideos ?? [] }
        if program.swapsData == nil { program.swaps = file.swaps ?? [] }

        // The video each name used before rows could have their own.
        var common: [String: [String: Int]] = [:]
        for item in file.weeks.flatMap(\.days).flatMap(\.items) {
            if let video = item.video { common[item.exercise.lowercased(), default: [:]][video, default: 0] += 1 }
        }
        for week in file.weeks {
            guard let model = program.week(week.number) else { continue }
            let days = model.sortedDays
            for (dayIndex, day) in week.days.enumerated() where days.indices.contains(dayIndex) {
                let items = days[dayIndex].sortedItems
                for (index, item) in day.items.enumerated() where items.indices.contains(index) {
                    let existing = items[index]
                    guard existing.exercise.lowercased() == item.exercise.lowercased() else { continue }
                    if existing.gauge == nil, let gauge = item.gauge { existing.gauge = gauge }
                    let old = common[item.exercise.lowercased()]?.max { $0.value < $1.value }?.key
                    if let video = item.video, existing.videoURL == old { existing.videoURL = video }
                }
            }
        }
        try? context.save()
        UserDefaults.standard.set(true, forKey: gaugesKey)
    }

    private static func load<T: Decodable>(_ type: T.Type, named name: String) throws -> T? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json") else { return nil }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    private static func insert(_ file: ProgramFile, into context: ModelContext) {
        let program = Program(name: file.name, author: file.author, summary: file.summary)
        program.percentBasis = file.percentBasis
        program.guidelines = file.guidelines
        program.basisVideos = file.basisVideos ?? []
        program.swaps = file.swaps ?? []
        context.insert(program)
        for week in file.weeks {
            let model = ProgramWeek(number: week.number)
            context.insert(model)
            model.decision = week.decision
            if let options = week.decisionOptions { model.decisionOptions = options }
            model.program = program
            for (index, day) in week.days.enumerated() {
                let plan = PlanDay(title: day.title, order: index)
                context.insert(plan)
                plan.restDaysBefore = day.restDaysBefore ?? 0
                plan.week = model
                add(day.items, to: plan, in: context)
            }
        }
        for (index, group) in file.asNeeded.enumerated() {
            let plan = PlanDay(title: group.title, order: index)
            context.insert(plan)
            plan.asNeededFor = program
            add(group.items, to: plan, in: context)
        }
    }

    private static func add(_ items: [ItemFile], to day: PlanDay, in context: ModelContext) {
        for (index, item) in items.enumerated() {
            let model = PlanItem(
                order: index, exercise: item.exercise,
                kind: ExerciseKind(rawValue: item.kind) ?? .strength,
                sets: item.sets, perSide: item.perSide, details: item.details, videoURL: item.video,
                gauge: item.gauge)
            context.insert(model)
            model.day = day
        }
    }

    private static func insert(_ file: PracticeFile, into context: ModelContext) {
        for (index, stage) in file.stages.enumerated() {
            context.insert(DunkStage(order: index, name: stage.name, detail: stage.detail,
                                     clearanceIn: stage.clearanceIn))
        }
        for (index, focus) in file.focuses.enumerated() {
            context.insert(PracticeFocus(order: index, name: focus.name, cue: focus.cue))
        }
    }

    // MARK: File shapes

    nonisolated struct ProgramFile: Decodable {
        var name: String
        var author: String
        var summary: String
        var percentBasis: String
        var guidelines: [String]
        var basisVideos: [VideoLink]?
        var swaps: [ExerciseSwap]?
        var weeks: [WeekFile]
        var asNeeded: [GroupFile]
    }

    nonisolated struct WeekFile: Decodable {
        var number: Int
        var days: [GroupFile]
        var decision: String?
        var decisionOptions: [DecisionOption]?
    }

    nonisolated struct GroupFile: Decodable {
        var title: String
        var items: [ItemFile]
        var restDaysBefore: Int?
    }

    nonisolated struct ItemFile: Decodable {
        var exercise: String
        var kind: String
        var sets: [SetSpec]
        var perSide: String?
        var details: String?
        var video: String?
        var gauge: Gauge?
    }

    nonisolated struct PracticeFile: Decodable {
        var stages: [Named]
        var focuses: [Focus]

        struct Named: Decodable { var name: String; var detail: String; var clearanceIn: Double }
        struct Focus: Decodable { var name: String; var cue: String }
    }
}
