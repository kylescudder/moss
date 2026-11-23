import Foundation

/// Moss's sync issue copy, layered on the shared `SyncIssueStore`.
extension SyncIssueStore {
    func reportRejectedTrip(_ error: TripCreationError) {
        switch error {
        case .freeLimitReached:
            report(SyncIssue(
                title: "Offline trip not synced",
                message: "The server rejected this trip because the lifetime free limit was reached. The local copy will be removed."
            ))
        case .subscriptionVerificationPending:
            report(SyncIssue(
                title: "Offline trip not synced",
                message: "The server could not verify Supporter access for this trip. Retry subscription verification before creating another trip."
            ))
        default:
            report(SyncIssue(
                title: "Offline change rejected",
                message: "The server rejected a locally saved trip. The local copy will be restored to the server version."
            ))
        }
    }

    func reportRejectedChange(table: String) {
        let subject = switch table {
        case "trips": "trip change"
        case "itinerary_items": "itinerary item"
        default: "profile change"
        }
        report(SyncIssue(
            title: "Offline change not synced",
            message: "The server rejected a locally saved \(subject). The local data will be restored to the server version."
        ))
    }
}
