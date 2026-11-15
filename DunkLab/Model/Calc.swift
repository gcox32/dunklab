import Foundation

// MARK: - Formatting

enum Fmt {
    /// 29.5 → "29½″"
    static func inches(_ value: Double) -> String {
        "\(number(value))″"
    }

    /// 124.5 → "10′ 4½″"
    static func feet(_ value: Double) -> String {
        let rounded = (value * 4).rounded() / 4
        let feet = Int(rounded / 12)
        let rest = rounded - Double(feet * 12)
        if rest == 0 { return "\(feet)′" }
        return "\(feet)′ \(number(rest))″"
    }

    /// Whole numbers plain, quarters as fraction glyphs, anything else to one place.
    static func number(_ value: Double) -> String {
        let sign = value < 0 ? "−" : ""
        let v = abs(value)
        let whole = v.rounded(.down)
        let fraction = v - whole
        let glyphs: [(Double, String)] = [(0, ""), (0.25, "¼"), (0.5, "½"), (0.75, "¾")]
        if let match = glyphs.first(where: { abs($0.0 - fraction) < 0.01 }) {
            let head = whole == 0 && !match.1.isEmpty ? "" : String(Int(whole))
            return sign + head + match.1
        }
        return sign + v.formatted(.number.precision(.fractionLength(1)))
    }

    static func pounds(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...1)))) lb"
    }

    /// "today", "tomorrow", "Wednesday", or "Oct 14" beyond a week out.
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "today" }
        if calendar.isDateInTomorrow(date) { return "tomorrow" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: .now), to: date).day ?? 0
        if days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func minutes(_ value: Double) -> String {
        let m = Int(value.rounded())
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }
}

// MARK: - Reactive strength

nonisolated enum Reactive {
    static let gravity = 9.81
    static let metersPerInch = 0.0254
    /// Longer than this on the ground, a drop jump or pogo has turned into a countermovement jump.
    static let maxReboundGroundTime = 0.25

    /// Jump height from time in the air: h = g·t²/8.
    static func heightMeters(flight: Double) -> Double { gravity * flight * flight / 8 }

    static func heightIn(flight: Double) -> Double { heightMeters(flight: flight) / metersPerInch }

    /// Height in meters over ground time in seconds. For a CMJ this is RSI-mod.
    static func rsi(groundTime: Double, flight: Double) -> Double {
        groundTime > 0 ? heightMeters(flight: flight) / groundTime : 0
    }

    static func counts(_ rep: JumpRep, kind: JumpTestKind) -> Bool {
        rep.groundTime > 0 && rep.flightTime > 0
            && (!kind.isRebound || rep.groundTime <= maxReboundGroundTime)
    }

    static func best(of reps: [JumpRep], kind: JumpTestKind) -> JumpRep? {
        reps.filter { counts($0, kind: kind) }.max { $0.rsi < $1.rsi }
    }

    /// A box height from a program note like "from ~75cm", to the nearest half inch.
    static func boxHeightIn(fromDetails details: String?) -> Double? {
        guard let details, let match = details.firstMatch(of: /(\d+(?:\.\d+)?)\s*cm/),
              let cm = Double(match.1) else { return nil }
        return (cm / 2.54 * 2).rounded() / 2
    }

    static func ms(_ seconds: Double) -> String { "\(Int((seconds * 1000).rounded())) ms" }

    static func rsiText(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(2))) }
}

// MARK: - Jump signals

nonisolated struct SignalPoint: Identifiable, Hashable {
    var date: Date
    var value: Double
    var id: Date { date }
}

nonisolated enum Signals {
    /// Squat max over bodyweight at every date either one changed, each using
    /// the latest value on or before that date. Starts once both exist.
    static func squatRatio(squats: [(date: Date, lb: Double)], weights: [(date: Date, lb: Double)]) -> [SignalPoint] {
        let squats = squats.sorted { $0.date < $1.date }
        let weights = weights.sorted { $0.date < $1.date }
        let dates = Set(squats.map(\.date) + weights.map(\.date)).sorted()
        return dates.compactMap { date in
            guard let squat = squats.last(where: { $0.date <= date }),
                  let weight = weights.last(where: { $0.date <= date }), weight.lb > 0 else { return nil }
            return SignalPoint(date: date, value: squat.lb / weight.lb)
        }
    }

    /// Each test's best RSI, oldest first. Tests with no rep that counts are left out.
    static func rsi(_ tests: [(date: Date, best: Double?)]) -> [SignalPoint] {
        tests.compactMap { test in test.best.map { SignalPoint(date: test.date, value: $0) } }
            .sorted { $0.date < $1.date }
    }

    static func ratioText(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(2))) }
}

// MARK: - Loads

enum Loads {
    /// Weight for a load, rounded to the nearest 5 lb.
    static func pounds(_ load: LoadSpec?, basis: Double?) -> Double? {
        guard let load else { return nil }
        if let pounds = load.pounds { return pounds }
        if let percent = load.percent, let basis {
            return (basis * percent / 100 / 5).rounded() * 5
        }
        return nil
    }

    static func describe(_ load: LoadSpec?, basis: Double?) -> String? {
        guard let load else { return nil }
        if let pounds = pounds(load, basis: basis) { return Fmt.pounds(pounds) }
        if let percent = load.percent { return "\(Fmt.number(percent))%" }
        if let effort = load.effort { return effort.label.lowercased() }
        if load.bodyweight == true { return "bodyweight" }
        return nil
    }

    /// "4 reps", "20 s", "30 m"
    static func volume(_ set: SetSpec) -> String? {
        if let reps = set.reps { return reps == 1 ? "1 rep" : "\(reps) reps" }
        if let seconds = set.seconds { return "\(seconds) s" }
        if let meters = set.meters { return "\(meters) m" }
        return nil
    }

    /// One line per run of identical sets: "4 × 4 reps at 205 lb".
    static func summary(_ sets: [SetSpec], basis: Double?, perSide: String?) -> [String] {
        var runs: [(SetSpec, Int)] = []
        for set in sets {
            if let last = runs.last, last.0 == set {
                runs[runs.count - 1].1 += 1
            } else {
                runs.append((set, 1))
            }
        }
        let side = perSide.map { " each \($0)" } ?? ""
        return runs.map { set, count in
            var parts: [String] = []
            let volume = volume(set) ?? (count == 1 ? "1 round" : "rounds")
            parts.append(count > 1 ? "\(count) × \(volume)" : volume)
            if let load = describe(set.load, basis: basis) { parts.append("at \(load)") }
            return parts.joined(separator: " ") + side
        }
    }

    /// Effort bands used anywhere in these sets, for the guide line under an exercise.
    static func efforts(_ sets: [SetSpec]) -> [Effort] {
        let used = Set(sets.compactMap { $0.load?.effort })
        return Effort.allCases.filter(used.contains)
    }
}

// MARK: - Body

struct NutritionTargets {
    var basisLb: Double
    var carbsG: Double
    var proteinG: Double
    var fatG: Double

    var calories: Double { carbsG * 4 + proteinG * 4 + fatG * 9 }

    /// Jump Science: per kg of lean bodyweight, carbs 3+ g, protein 1.5 g, fat 1 g.
    /// If you're above lean, use the weight you'd be at lean.
    static func make(weightLb: Double, bodyFatPct: Double?, leanPct: Double) -> NutritionTargets {
        var basis = weightLb
        if let bodyFatPct, bodyFatPct > leanPct {
            basis = weightLb * (1 - bodyFatPct / 100) / (1 - leanPct / 100)
        }
        let kg = basis / 2.20462
        return NutritionTargets(basisLb: basis, carbsG: kg * 3, proteinG: kg * 1.5, fatG: kg)
    }
}

// MARK: - Schedule

/// A program workout projected onto a future date.
struct PlannedWorkout: Identifiable {
    let date: Date
    let week: Int
    let day: PlanDay

    var id: String { "\(week)-\(day.order)-\(date.timeIntervalSince1970)" }
    var title: String { "Week \(week), \(day.title.lowercased())" }
}

enum Schedule {
    /// When the program's most recent workout was finished.
    static func lastWorkout(in program: Program, logs: [WorkoutLog]) -> Date? {
        logs.compactMap { log in
            log.sourceDay?.week?.program?.persistentModelID == program.persistentModelID ? log.finishedAt : nil
        }
        .max()
    }

    /// When the program week holding the most recent workout was opened, if its
    /// first day was logged.
    private static func lastWeekOpened(in program: Program, logs: [WorkoutLog]) -> Date? {
        let finished = logs.filter {
            $0.finishedAt != nil && $0.sourceDay?.week?.program?.persistentModelID == program.persistentModelID
        }
        guard let week = finished.max(by: { $0.finishedAt! < $1.finishedAt! })?.sourceDay?.week else { return nil }
        return finished.filter {
            $0.sourceDay?.order == 0 && $0.sourceDay?.week?.persistentModelID == week.persistentModelID
        }
        .compactMap(\.finishedAt)
        .max()
    }

    /// The first day `day` should be trained. Never earlier than today.
    static func readyDate(for day: PlanDay, in program: Program, logs: [WorkoutLog]) -> Date {
        let today = Calendar.training.startOfDay(for: .now)
        guard let last = lastWorkout(in: program, logs: logs) else { return today }
        return max(earliest(day, after: last, weekOpened: lastWeekOpened(in: program, logs: logs)), today)
    }

    /// Leaves the day's rest days after the previous workout. The first day of a
    /// program week also waits for the calendar week after the previous program week
    /// opened, so a three-day week runs Monday, Wednesday, Friday rather than rolling
    /// into Sunday, while a week that spilled into a new calendar week adds no wait.
    private static func earliest(_ day: PlanDay, after previous: Date, weekOpened: Date?) -> Date {
        let calendar = Calendar.training
        let last = calendar.startOfDay(for: previous)
        var ready = calendar.date(byAdding: .day, value: day.restDaysBefore + 1, to: last) ?? last
        if day.order == 0, let weekOpened {
            ready = max(ready, calendar.currentWeek(containing: weekOpened).end)
        }
        return ready
    }

    /// The program's next workouts on their earliest dates, up to a horizon.
    /// Stops at a decision point, since the path after it isn't chosen yet.
    static func upcoming(for program: Program, logs: [WorkoutLog], days horizon: Int = 60) -> [PlannedWorkout] {
        guard program.isActive, !program.awaitingDecision, var day = program.nextDay else { return [] }
        let calendar = Calendar.training
        let end = calendar.date(byAdding: .day, value: horizon, to: calendar.startOfDay(for: .now)) ?? .now
        var weekNumber = program.currentWeek
        var index = program.currentDay
        var date = readyDate(for: day, in: program, logs: logs)
        var weekOpened = day.order == 0 ? date : lastWeekOpened(in: program, logs: logs)
        var plan: [PlannedWorkout] = []

        while date <= end {
            plan.append(PlannedWorkout(date: date, week: weekNumber, day: day))
            guard let week = program.week(weekNumber) else { break }
            if index + 1 < week.days.count {
                index += 1
            } else {
                guard week.decision == nil, program.week(weekNumber + 1) != nil else { break }
                weekNumber += 1
                index = 0
            }
            guard let next = program.week(weekNumber)?.sortedDays[safe: index] else { break }
            day = next
            date = earliest(day, after: date, weekOpened: weekOpened)
            if day.order == 0 { weekOpened = date }
        }
        return plan
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Weeks

extension Calendar {
    /// Training weeks run Monday to Sunday, matching the program's MWF example,
    /// whatever the locale's first weekday is.
    static var training: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar
    }

    func currentWeek(containing date: Date = .now) -> DateInterval {
        dateInterval(of: .weekOfYear, for: date) ?? DateInterval(start: date, duration: 7 * 86400)
    }
}
