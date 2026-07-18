import Foundation
import Supabase

@MainActor
final class TripsRepository: ObservableObject {
    @Published private(set) var trips: [Trip] = []
    @Published private(set) var isLoading = false
    @Published var lastError: String?

    private let auth: AuthClient

    init(auth: AuthClient) {
        self.auth = auth
    }

    func reset() {
        trips = []
        lastError = nil
    }

    func refresh() async {
        guard auth.currentUserID != nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let response: [Trip] = try await auth.supabase
                .from("trips")
                .select()
                .is("deleted_at", value: nil)
                .order("starts_at", ascending: true)
                .execute()
                .value
            trips = response
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "trips.refresh")
        }
    }

    func activeTripCount() async -> Int {
        if trips.isEmpty {
            await refresh()
        }
        return trips.count
    }

    func create(_ draft: TripDraft) async -> Trip? {
        guard let userID = auth.currentUserID else { return nil }
        do {
            let payload = TripInsert(
                ownerID: userID,
                title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                destination: draft.destination.trimmingCharacters(in: .whitespacesAndNewlines),
                startsAt: draft.startsAt,
                endsAt: draft.endsAt,
                notes: draft.notes.nilIfBlank
            )
            let trip: Trip = try await auth.supabase
                .from("trips")
                .insert(payload)
                .select()
                .single()
                .execute()
                .value
            trips.append(trip)
            trips.sort { ($0.startsAt ?? .distantFuture) < ($1.startsAt ?? .distantFuture) }
            return trip
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "trips.create")
            return nil
        }
    }

    func update(_ trip: Trip) async {
        do {
            let payload = TripUpdate(
                title: trip.title,
                destination: trip.destination,
                startsAt: trip.startsAt,
                endsAt: trip.endsAt,
                notes: trip.notes
            )
            let updated: Trip = try await auth.supabase
                .from("trips")
                .update(payload)
                .eq("id", value: trip.id.uuidString)
                .select()
                .single()
                .execute()
                .value
            if let index = trips.firstIndex(where: { $0.id == updated.id }) {
                trips[index] = updated
            }
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "trips.update")
        }
    }

    func softDelete(_ trip: Trip) async {
        do {
            try await auth.supabase
                .from("trips")
                .update(["deleted_at": ISO8601DateFormatter().string(from: Date())])
                .eq("id", value: trip.id.uuidString)
                .execute()
            trips.removeAll { $0.id == trip.id }
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "trips.delete")
        }
    }
}

private struct TripInsert: Encodable {
    let ownerID: UUID
    let title: String
    let destination: String
    let startsAt: Date
    let endsAt: Date
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case ownerID = "owner_id"
        case title
        case destination
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case notes
    }
}

private struct TripUpdate: Encodable {
    let title: String
    let destination: String
    let startsAt: Date?
    let endsAt: Date?
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case title
        case destination
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case notes
    }
}

