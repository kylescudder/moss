import Combine
import Foundation

struct SyncIssue: Identifiable, Equatable, Sendable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor final class SyncIssueStore: ObservableObject {
    @Published var current: SyncIssue?
    func rejectedTrip(_ error: TripCreationError) {
        current = SyncIssue(title: "Offline trip not synced", message: error == .quotaReached
            ? "The server rejected this trip because your lifetime free allowance was reached. The local copy will be removed."
            : "The server rejected this locally saved trip. The local copy will be restored to server state.")
    }
    func rejectedChange(table: String) {
        current = SyncIssue(title: "Offline change not synced", message: "The server rejected a locally saved \(table == "itinerary_items" ? "itinerary item" : "profile change"). Server state will be restored.")
    }
    func localClearFailed() {
        current = SyncIssue(title: "Offline data not cleared", message: "Moss could not clear this account's offline data. Another account cannot sync until clearing succeeds.")
    }
}
