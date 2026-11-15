import SwiftData
import SwiftUI

struct TodayView: View {
    let athlete: Athlete

    @Environment(\.modelContext) private var context
    @Query(sort: \TouchRecord.heightIn, order: .reverse) private var touches: [TouchRecord]
    @Query(sort: \DunkStage.order) private var stages: [DunkStage]
    // Sorted and filtered in code; see CalendarView on `isActive` predicate queries.
    @Query(sort: \Program.createdAt) private var programs: [Program]
    private var active: [Program] { programs.filter(\.isActive) }
    @Query(sort: \StrengthTest.date, order: .reverse) private var tests: [StrengthTest]
    @Query(sort: \PracticeSession.startedAt, order: .reverse) private var sessions: [PracticeSession]
    @Query(sort: \WorkoutLog.startedAt, order: .reverse) private var logs: [WorkoutLog]

    @State private var runningLog: WorkoutLog?
    @State private var showingCalendar = UserDefaults.standard.string(forKey: "open") == "calendar"

    private var best: TouchRecord? { touches.first }
    private var goal: DunkStage? { DunkStage.goal(in: stages) }
    private var week: DateInterval { Calendar.training.currentWeek() }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    headline
                    VStack(alignment: .leading, spacing: 10) {
                        ReachLadder(best: best?.heightIn, marks: marks, floor: ladderFloor)
                            .frame(height: 420)
                        Text(reachLine)
                            .font(.subheadline)
                            .foregroundStyle(Palette.inkSoft)
                    }
                    nextUp
                    thisWeek
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .background(Palette.backboard)
            .toolbarVisibility(.hidden, for: .navigationBar)
            .fullScreenCover(item: $runningLog) { WorkoutSessionView(log: $0) }
            .navigationDestination(isPresented: $showingCalendar) { CalendarView(athlete: athlete) }
            #if DEBUG
            .task {
                if UserDefaults.standard.string(forKey: "open") == "workout", let day = active.first?.nextDay {
                    runningLog = WorkoutFactory.start(day, basis: tests.first?.weightLb, in: context)
                }
            }
            #endif
        }
    }

    // MARK: Headline

    private var headline: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(goal?.name ?? "Every dunk landed")
                .font(.system(size: 44, weight: .heavy).width(.compressed))
                .foregroundStyle(Palette.ink)
            Text(gapSentence)
                .font(.title3)
                .foregroundStyle(Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var gapSentence: String {
        guard let goal else { return "Add a harder dunk to your ladder in Practice." }
        guard let best else { return "Log a touch in Practice to see how close it is." }
        let gap = athlete.line(for: goal) - best.heightIn
        let estimate = best.isEstimate ? " (estimated)" : ""
        if gap > 0 {
            return "Your best touch\(estimate) is \(Fmt.inches(gap)) short of it."
        }
        return "Your best touch\(estimate) clears it by \(Fmt.inches(-gap)). The height is there. Go land it."
    }

    private var marks: [LadderMark] {
        var marks = [
            LadderMark(value: athlete.rimHeightIn, label: "Rim", style: .rim),
        ]
        if let goal {
            marks.append(LadderMark(value: athlete.line(for: goal), label: goal.name, style: .goal))
            let after = stages.filter { !$0.isLanded && $0.order > goal.order && $0.clearanceIn > goal.clearanceIn }
            if let next = after.first {
                marks.append(LadderMark(value: athlete.line(for: next), label: next.name, style: .nextDunk))
            }
        }
        if let best {
            marks.append(LadderMark(
                value: best.heightIn,
                label: best.isEstimate ? "Best touch, estimated" : "Best touch",
                style: .touch))
        }
        return marks
    }

    private var ladderFloor: Double {
        let low = min(athlete.rimHeightIn, best?.heightIn ?? athlete.rimHeightIn)
        return max((low - 6).rounded(.down), athlete.standingReachIn)
    }

    private var reachLine: String {
        let reach = "Standing reach \(Fmt.feet(athlete.standingReachIn))"
        guard let best else { return reach + "." }
        return reach + ", so that touch is a \(Fmt.inches(best.heightIn - athlete.standingReachIn)) vertical."
    }

    // MARK: Next up

    @ViewBuilder
    private var nextUp: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Next workout")
            if let program = active.first {
                if program.awaitingDecision {
                    NavigationLink {
                        DecisionView(program: program)
                    } label: {
                        row(
                            title: "Week \(program.currentWeek) is done",
                            detail: "Time to decide where the program goes next.",
                            symbol: "arrow.triangle.branch")
                    }
                } else if let day = program.nextDay {
                    let ready = Schedule.readyDate(for: day, in: program, logs: logs)
                    let isRestDay = !Calendar.current.isDateInToday(ready)
                    let name = "Week \(program.currentWeek), \(day.title.lowercased())"
                    let exercises = day.sortedItems.filter { $0.kind != .warmup }
                        .prefix(4).map(\.exercise).joined(separator: ", ")
                    VStack(alignment: .leading, spacing: 14) {
                        NavigationLink {
                            PlanDayView(day: day)
                        } label: {
                            if isRestDay {
                                row(title: "Rest day",
                                    detail: "\(name) is ready \(Fmt.day(ready)): \(exercises).",
                                    symbol: "chevron.right")
                            } else {
                                row(title: name, detail: exercises, symbol: "chevron.right")
                            }
                        }
                        if isRestDay {
                            Text("Recovery is when the training turns into jumping. Isometrics and stretching are fine today.")
                                .font(.subheadline)
                                .foregroundStyle(Palette.inkSoft)
                            Button("Start anyway") {
                                runningLog = WorkoutFactory.start(day, basis: tests.first?.weightLb, in: context)
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button("Start workout") {
                                runningLog = WorkoutFactory.start(day, basis: tests.first?.weightLb, in: context)
                            }
                            .buttonStyle(BigButtonStyle())
                        }
                    }
                }
            } else {
                Text("Follow a program or build your own workout in Train.")
                    .foregroundStyle(Palette.inkSoft)
            }
        }
    }

    private func row(title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(Palette.ink)
                Text(detail).font(.subheadline).foregroundStyle(Palette.inkSoft)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            Image(systemName: symbol).foregroundStyle(Palette.inkSoft)
        }
        .contentShape(.rect)
    }

    // MARK: This week

    private var thisWeek: some View {
        let practice = sessions.filter { week.contains($0.startedAt) }
        let minutes = practice.reduce(0) { $0 + $1.minutes }
        let planned = active.first.map { Schedule.upcoming(for: $0, logs: logs, days: 7) } ?? []
        let index = CalendarIndex(logs: logs, sessions: sessions, planned: planned)
        return VStack(alignment: .leading, spacing: 16) {
            NavigationLink {
                CalendarView(athlete: athlete)
            } label: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        SectionTitle("This week")
                        Spacer()
                        Text("Calendar").font(.subheadline)
                        Image(systemName: "chevron.right").font(.subheadline)
                    }
                    .foregroundStyle(Palette.inkSoft)
                    WeekStrip(index: index)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            PlayBudgetBar(minutes: minutes, budget: Double(athlete.weeklyPlayMinutes))
        }
    }
}

/// Practice and play minutes against the weekly budget.
struct PlayBudgetBar: View {
    var minutes: Double
    var budget: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Practice and play")
                Spacer()
                Text("\(Fmt.minutes(minutes)) of \(Fmt.minutes(budget))")
                    .font(.readout(.title3))
                    .monospacedDigit()
            }
            GeometryReader { geo in
                let fraction = min(minutes / max(budget, 1), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.chalk)
                    Capsule()
                        .fill(minutes > budget ? Palette.vaneRed : Palette.vaneBlue)
                        .frame(width: max(geo.size.width * fraction, minutes > 0 ? 8 : 0))
                }
            }
            .frame(height: 8)
            Text(minutes > budget
                 ? "Over budget. Extra play slows how fast the training shows up."
                 : "Dunk sessions count toward the 2–3 hours of sport play the PhD Program allows each week.")
                .font(.caption)
                .foregroundStyle(Palette.inkSoft)
        }
    }
}
