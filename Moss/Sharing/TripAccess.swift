import Foundation

/// What the signed-in account may do with a trip. A trip is reachable through
/// its own members (`tripSharing`) and through its owner's library
/// (`librarySharing`); the stronger role wins. The server enforces the same
/// rules, so these only decide what the UI offers.
extension AppServices {
    var currentUserID: String? { auth.currentUserID?.uuidString.lowercased() }

    func role(for trip: Trip) -> ShareRole? {
        guard let userID = currentUserID else { return nil }
        let ownerID = trip.ownerID.uuidString.lowercased()
        if ownerID == userID { return .owner }
        return [
            tripSharing.role(in: trip.id.uuidString.lowercased(), userID: userID),
            librarySharing.role(in: ownerID, userID: userID),
        ]
        .compactMap { $0 }
        .max()
    }

    func isOwner(of trip: Trip) -> Bool { role(for: trip) == .owner }

    func canEdit(_ trip: Trip) -> Bool { role(for: trip)?.canEdit == true }

    /// The owner's name for a trip someone shared with this account.
    func ownerName(of trip: Trip) -> String? {
        let ownerID = trip.ownerID.uuidString.lowercased()
        return tripSharing.displayName(for: ownerID) ?? librarySharing.displayName(for: ownerID)
    }

    /// A short line for trip rows: who shared it, or that the owner shared it.
    func sharingSummary(for trip: Trip) -> String? {
        if isOwner(of: trip) {
            let shared = tripSharing.isShared(trip.id.uuidString.lowercased())
                || currentUserID.map(librarySharing.isShared) == true
            return shared ? "Shared" : nil
        }
        return ownerName(of: trip).map { "Shared by \($0)" } ?? "Shared with you"
    }
}
