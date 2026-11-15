import SwiftData
import SwiftUI

/// Everything logged or planned on one day.
struct DayRecord {
    var workouts: [WorkoutLog] = []
    var sessions: [PracticeSession] = []
    var planned: [PlannedWorkout] = []
    var body: [BodyEntry] = []
    var tests: [StrengthTest] = []
    var touches: [TouchRecord] = []

    var isEmpty: Bool {
        workouts.isEmpty && sessions.isEmpty && planned.isEmpty && body.isEmpty && tests.isEmpty && touches.isEmpty
    }
}

/// Groups records by day, keyed by the start of the day.
struct CalendarIndex {
    private var days: [Date: DayRecord] = [:]
    private let calendar = Calendar.training

    init(logs: [WorkoutLog], sessions: [PracticeSession], planned: [PlannedWorkout],
         body: [BodyEntry] = [], tests: [StrengthTest] = [], touches: [TouchRecord] = []) {
        for log in logs { days[key(log.startedAt), default: DayRecord()].workouts.append(log) }
        for session in sessions { days[key(session.startedAt), default: DayRecord()].sessions.append(session) }
        for plan in planned { days[key(plan.date), default: DayRecord()].planned.append(plan) }
        for entry in body { days[key(entry.date), default: DayRecord()].body.append(entry) }
        for test in tests { days[key(test.date), default: DayRecord()].tests.append(test) }
        // Touches from a session are shown with the session.
        for touch in touches where touch.session == nil {
            days[key(touch.date), default: DayRecord()].touches.append(touch)
        }
    }

    subscript(date: Date) -> DayRecord { days[key(date)] ?? DayRecord() }

    private func key(_ date: Date) -> Date { calendar.startOfDay(for: date) }
}

/// Small marks under a date: a bar for a workout done, an outline for one planned,
/// and a dot for practice.
struct DayMarks: View {
    let record: DayRecord

    var body: some View {
        HStack(spacing: 3) {
            if !record.workouts.isEmpty {
                Capsule().fill(Palette.vaneBlue).frame(width: 12, height: 5)
            } else if !record.planned.isEmpty {
                Capsule().strokeBorder(Palette.vaneBlue, lineWidth: 1.5).frame(width: 12, height: 5)
            }
            if !record.sessions.isEmpty {
                Circle().fill(Palette.ink).frame(width: 5, height: 5)
            }
        }
        .frame(height: 6)
    }
}

/// One date in a strip or grid.
struct DayCell: View {
    let date: Date
    let record: DayRecord
    var isSelected = false
    var dimmed = false

    private var isToday: Bool { Calendar.training.isDateInToday(date) }

    var body: some View {
        VStack(spacing: 5) {
            Text(date.formatted(.dateTime.day()))
                .font(.readout(.title3))
                .monospacedDigit()
                .foregroundStyle(isSelected ? Color.white : isToday ? Palette.vaneBlue : Palette.ink)
                .frame(width: 36, height: 36)
                .background {
                    if isSelected {
                        Circle().fill(Palette.ink)
                    } else if isToday {
                        Circle().strokeBorder(Palette.vaneBlue, lineWidth: 1.5)
                    }
                }
            DayMarks(record: record)
        }
        .opacity(dimmed ? 0.35 : 1)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [date.formatted(date: .complete, time: .omitted)]
        if !record.workouts.isEmpty { parts.append("workout done") }
        else if !record.planned.isEmpty { parts.append("workout planned") }
        if !record.sessions.isEmpty { parts.append("practice") }
        return parts.joined(separator: ", ")
    }
}

/// Monday to Sunday of the current week.
struct WeekStrip: View {
    let index: CalendarIndex

    var body: some View {
        let calendar = Calendar.training
        let start = calendar.currentWeek().start
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        VStack(spacing: 6) {
            HStack {
                ForEach(days, id: \.self) { day in
                    Text(day.formatted(.dateTime.weekday(.narrow)))
                        .font(.caption)
                        .foregroundStyle(Palette.inkSoft)
                        .frame(maxWidth: .infinity)
                }
            }
            HStack {
                ForEach(days, id: \.self) { day in
                    DayCell(date: day, record: index[day])
                }
            }
        }
    }
}

struct CalendarView: View {
    let athlete: Athlete

    @Query(sort: \WorkoutLog.startedAt) private var logs: [WorkoutLog]
    @Query(sort: \PracticeSession.startedAt) private var sessions: [PracticeSession]
    @Query(sort: \BodyEntry.date) private var bodyEntries: [BodyEntry]
    @Query(sort: \StrengthTest.date) private var tests: [StrengthTest]
    @Query(sort: \TouchRecord.date) private var touches: [TouchRecord]
    // Not a `#Predicate { $0.isActive }` query: in a pushed view that query
    // invalidates itself on every update and the screen never settles.
    @Query(sort: \Program.createdAt) private var programs: [Program]

    @State private var month = Calendar.training.dateInterval(of: .month, for: .now)?.start ?? .now
    @State private var selected = Calendar.training.startOfDay(for: .now)

    private let calendar = Calendar.training

    private var planned: [PlannedWorkout] {
        programs.first { $0.isActive }.map { Schedule.upcoming(for: $0, logs: logs) } ?? []
    }

    var body: some View {
        let index = CalendarIndex(logs: logs, sessions: sessions, planned: planned,
                                  body: bodyEntries, tests: tests, touches: touches)
        List {
            Section {
                monthHeader
                monthGrid(index)
            } footer: {
                legend
            }
            Section {
                agenda(index[selected])
            } header: {
                SectionTitle(selected.formatted(.dateTime.weekday(.wide).month(.wide).day()))
            }
        }
        .navigationTitle("Calendar")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Month

    private var monthHeader: some View {
        HStack {
            Text(month.formatted(.dateTime.month(.wide).year()))
                .font(.readout(.title2))
            Spacer()
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left").padding(8) }
                .accessibilityLabel("Previous month")
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right").padding(8) }
                .accessibilityLabel("Next month")
        }
        .buttonStyle(.borderless)
    }

    /// Plain rows, not a lazy grid: a lazy grid inside a List row keeps
    /// re-measuring itself and never settles.
    private func monthGrid(_ index: CalendarIndex) -> some View {
        let days = gridDays
        let weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
        return VStack(spacing: 10) {
            HStack(spacing: 0) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol).font(.caption).foregroundStyle(Palette.inkSoft).frame(maxWidth: .infinity)
                }
            }
            ForEach(weeks, id: \.first) { week in
                HStack(spacing: 0) {
                    ForEach(week, id: \.self) { day in
                        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
                        Button {
                            selected = day
                        } label: {
                            DayCell(date: day, record: index[day],
                                    isSelected: calendar.isDate(day, inSameDayAs: selected), dimmed: !inMonth)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(Capsule().fill(Palette.vaneBlue).frame(width: 12, height: 5), "Workout")
            legendItem(Capsule().strokeBorder(Palette.vaneBlue, lineWidth: 1.5).frame(width: 12, height: 5), "Planned")
            legendItem(Circle().fill(Palette.ink).frame(width: 5, height: 5), "Practice")
        }
    }

    private func legendItem(_ mark: some View, _ label: String) -> some View {
        HStack(spacing: 5) {
            mark
            Text(label)
        }
    }

    /// Monday-first symbols, whatever the locale's first weekday.
    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return Array(symbols[1...] + symbols[..<1])
    }

    /// Whole weeks covering the month.
    private var gridDays: [Date] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let first = calendar.dateInterval(of: .weekOfYear, for: interval.start)?.start,
              let last = calendar.dateInterval(of: .weekOfYear, for: interval.end.addingTimeInterval(-1))?.end
        else { return [] }
        var days: [Date] = []
        var day = first
        while day < last {
            days.append(day)
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? last
        }
        return days
    }

    private func shiftMonth(_ delta: Int) {
        month = calendar.date(byAdding: .month, value: delta, to: month) ?? month
    }

    // MARK: Day

    @ViewBuilder
    private func agenda(_ record: DayRecord) -> some View {
        if record.isEmpty {
            Text(selected > calendar.startOfDay(for: .now) ? "Nothing planned. Rest day." : "Nothing logged.")
                .foregroundStyle(Palette.inkSoft)
        }
        ForEach(record.planned) { plan in
            NavigationLink {
                PlanDayView(day: plan.day)
            } label: {
                agendaRow(plan.title, detail: plan.day.sortedItems.filter { $0.kind != .warmup }
                    .prefix(3).map(\.exercise).joined(separator: ", "), tag: "Planned")
            }
        }
        ForEach(record.workouts) { log in
            NavigationLink {
                WorkoutLogDetail(log: log)
            } label: {
                agendaRow(log.context.map { "\($0), \(log.title.lowercased())" } ?? log.title,
                          detail: "\(log.entries.count) exercises",
                          tag: log.finishedAt == nil ? "Not finished" : nil)
            }
        }
        ForEach(record.sessions) { session in
            NavigationLink {
                SessionDetail(session: session, athlete: athlete)
            } label: {
                agendaRow("Practice: \(session.focus.lowercased())",
                          detail: "\(session.makes) of \(session.attempts.count) on \(session.stage.lowercased()), \(Fmt.minutes(session.minutes))",
                          tag: session.finishedAt == nil ? "Never ended" : nil)
            }
        }
        ForEach(record.tests) { test in
            LabeledContent("Max deep squat", value: Fmt.pounds(test.weightLb))
        }
        ForEach(record.touches) { touch in
            LabeledContent(touch.isEstimate ? "Touch, estimated" : "Touch", value: Fmt.feet(touch.heightIn))
        }
        ForEach(record.body) { entry in
            LabeledContent("Body", value: [entry.weightLb.map(Fmt.pounds), entry.bodyFatPct.map { "\(Fmt.number($0))%" }]
                .compactMap { $0 }.joined(separator: ", "))
        }
    }

    private func agendaRow(_ title: String, detail: String, tag: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                if let tag {
                    Text(tag)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tag == "Planned" ? Palette.vaneBlue : Palette.vaneRed)
                }
            }
            Text(detail).font(.caption).foregroundStyle(Palette.inkSoft).lineLimit(1)
        }
    }
}
