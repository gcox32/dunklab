import SwiftData
import SwiftUI

struct OnboardingView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \DunkStage.order) private var stages: [DunkStage]
    @Query(sort: \Program.createdAt) private var programs: [Program]

    @State private var height: Double?
    @State private var reach: Double?
    @State private var weight: Double?
    @State private var bodyFat: Double?
    @State private var squat: Double?
    @State private var touch: Double?
    @State private var touchIsEstimate = true
    @State private var landed: Set<PersistentIdentifier> = []
    @State private var followProgram = true

    private var canStart: Bool { height != nil && reach != nil && weight != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("A few numbers to start. You can change any of them later.")
                        .foregroundStyle(Palette.inkSoft)
                }
                Section {
                    MeasureField("Height", value: $height, unit: "in", showFeet: true)
                    MeasureField("Standing reach", value: $reach, unit: "in", showFeet: true)
                    MeasureField("Weight", value: $weight, unit: "lb")
                    MeasureField("Body fat", value: $bodyFat, unit: "%", prompt: "Optional")
                } header: {
                    SectionTitle("You")
                }
                Section {
                    MeasureField("Max deep squat", value: $squat, unit: "lb", prompt: "Optional")
                } header: {
                    SectionTitle("Strength")
                } footer: {
                    Text("Every percentage in the PhD Program refers to this lift.")
                }
                Section {
                    MeasureField("Best touch", value: $touch, unit: "in", showFeet: true, prompt: "Optional")
                    if touch != nil {
                        Toggle("That's an estimate", isOn: $touchIsEstimate)
                    }
                } header: {
                    SectionTitle("Jumping")
                } footer: {
                    Text("Your highest hand touch on an approach jump. A max-touch practice session will replace an estimate with a real number.")
                }
                Section {
                    ForEach(stages) { stage in
                        Button {
                            toggle(stage)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(stage.name).foregroundStyle(Palette.ink)
                                    Text("Hand about \(Fmt.inches(stage.clearanceIn)) above the rim")
                                        .font(.caption)
                                        .foregroundStyle(Palette.inkSoft)
                                }
                                Spacer()
                                Image(systemName: landed.contains(stage.persistentModelID) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(Palette.vaneBlue)
                            }
                        }
                    }
                } header: {
                    SectionTitle("Dunks you can already do")
                } footer: {
                    Text("Your goal becomes the first dunk you can't do yet. Edit the list any time in Practice.")
                }
                if let program = programs.first {
                    Section {
                        Toggle("Follow the \(program.name)", isOn: $followProgram)
                    } footer: {
                        Text(program.summary)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Dunk Lab")
            .safeAreaInset(edge: .bottom) {
                Button("Start training", action: start)
                    .buttonStyle(BigButtonStyle())
                    .disabled(!canStart)
                    .opacity(canStart ? 1 : 0.4)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
        }
    }

    private func toggle(_ stage: DunkStage) {
        if landed.contains(stage.persistentModelID) {
            landed.remove(stage.persistentModelID)
        } else {
            landed.insert(stage.persistentModelID)
        }
    }

    private func start() {
        guard let height, let reach, let weight else { return }
        let athlete = Athlete()
        athlete.heightIn = height
        athlete.standingReachIn = reach
        context.insert(athlete)
        context.insert(BodyEntry(weightLb: weight, bodyFatPct: bodyFat))
        if let squat { context.insert(StrengthTest(weightLb: squat)) }
        if let touch { context.insert(TouchRecord(heightIn: touch, isEstimate: touchIsEstimate)) }
        for stage in stages where landed.contains(stage.persistentModelID) {
            stage.ownedAt = .now
        }
        if followProgram, let program = programs.first {
            program.isActive = true
            program.jump(toWeek: program.sortedWeeks.first?.number ?? 1)
        }
        try? context.save()
    }
}
