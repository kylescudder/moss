import AppIntents

struct MossShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NewTripIntent(),
            phrases: [
                "Plan a trip in \(.applicationName)",
                "New trip in \(.applicationName)"
            ],
            shortTitle: "New trip",
            systemImageName: "suitcase"
        )
        AppShortcut(
            intent: ShowTodayIntent(),
            phrases: [
                "What's on today in \(.applicationName)",
                "Show today in \(.applicationName)"
            ],
            shortTitle: "Today",
            systemImageName: "sun.max"
        )
    }
}
