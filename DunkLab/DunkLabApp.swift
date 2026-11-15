import SwiftData
import SwiftUI

/// The one data store. Static so Live Activity buttons, which can wake the app
/// in the background, write through the same context the screens use.
enum AppStore {
    static let container: ModelContainer = {
        do {
            return try ModelContainer(for: Schema(AppSchema.models))
        } catch {
            fatalError("Couldn't open the data store: \(error)")
        }
    }()
}

@main
struct DunkLabApp: App {
    init() {
        Appearance.apply()
        Seed.importIfNeeded(into: AppStore.container.mainContext)
        #if DEBUG
        DebugFixtures.applyLaunchArguments(to: AppStore.container.mainContext)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(AppStore.container)
    }
}

struct RootView: View {
    @Query private var athletes: [Athlete]

    var body: some View {
        if let athlete = athletes.first {
            MainTabs(athlete: athlete)
        } else {
            OnboardingView()
        }
    }
}

struct MainTabs: View {
    let athlete: Athlete

    // Debug builds accept `-tab practice` to open on a tab.
    @State private var selection = UserDefaults.standard.string(forKey: "tab") ?? "today"

    var body: some View {
        TabView(selection: $selection) {
            Tab("Today", systemImage: "ruler", value: "today") { TodayView(athlete: athlete) }
            Tab("Practice", systemImage: "basketball", value: "practice") { PracticeView(athlete: athlete) }
            Tab("Train", systemImage: "dumbbell", value: "train") { TrainView() }
            Tab("Body", systemImage: "figure.stand", value: "body") { BodyView(athlete: athlete) }
        }
        .tint(Palette.vaneBlue)
    }
}
