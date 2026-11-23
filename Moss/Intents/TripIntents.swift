import AppIntents
import Foundation

struct NewTripIntent: AppIntent {
    static let title: LocalizedStringResource = "New Trip"
    static let description = IntentDescription("Open Moss ready to plan a new trip.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickActionRouter.handle(.newTrip)
        return .result()
    }
}

struct ShowTodayIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Today"
    static let description = IntentDescription("Open Moss to today's plans.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickActionRouter.handle(.today)
        return .result()
    }
}
