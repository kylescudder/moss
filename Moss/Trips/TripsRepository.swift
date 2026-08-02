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

    func creationStatus() async throws -> TripCreationStatus {
        let statuses: [TripCreationStatus] = try await auth.supabase
            .rpc("get_trip_creation_status")
            .execute()
            .value
        guard let status = statuses.first else {
            throw TripCreationError.unknown("Moss returned an empty trip allowance status.")
        }
        return status
    }

    func lifetimeTripCount() async throws -> Int {
        try await creationStatus().lifetimeTripCount
    }

    func create(_ draft: TripDraft) async -> Result<Trip, TripCreationError> {
        guard let userID = auth.currentUserID else {
            return .failure(.authenticationRequired)
        }
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
            return .success(trip)
        } catch {
            let creationError = Self.classifyCreationError(error)
            lastError = creationError.errorDescription
            Log.error(error, category: "trips.create")
            return .failure(creationError)
        }
    }

    static func classifyCreationError(_ error: Error) -> TripCreationError {
        if let postgrestError = error as? PostgrestError {
            switch (postgrestError.code, postgrestError.detail) {
            case ("MS001", "MOSS_TRIP_LIMIT_REACHED"):
                return .quotaReached
            case ("MS002", "MOSS_SUBSCRIPTION_VERIFICATION_PENDING"):
                return .subscriptionVerificationPending
            case ("28000", "MOSS_AUTHENTICATION_REQUIRED"),
                 ("PGRST301", _),
                 ("PGRST302", _),
                 ("PGRST303", _):
                return .authenticationRequired
            default:
                if let code = postgrestError.code,
                   code == "42501"
                    || code.hasPrefix("22")
                    || code.hasPrefix("23")
                    || code.hasPrefix("PGRST") {
                    return .serverValidation(postgrestError.message)
                }
                return .unknown(postgrestError.message)
            }
        }

        if let urlError = error as? URLError {
            return .connectivity(urlError.localizedDescription)
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return .connectivity(nsError.localizedDescription)
        }

        return .unknown(error.localizedDescription)
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

struct TripCreationStatus: Decodable, Equatable {
    let lifetimeTripCount: Int
    let freeTripAllowance: Int
    let hasActiveEntitlement: Bool
    let subscriptionVerificationPending: Bool
    let canCreateTrip: Bool

    enum CodingKeys: String, CodingKey {
        case lifetimeTripCount = "lifetime_trip_count"
        case freeTripAllowance = "free_trip_allowance"
        case hasActiveEntitlement = "has_active_entitlement"
        case subscriptionVerificationPending = "subscription_verification_pending"
        case canCreateTrip = "can_create_trip"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lifetimeTripCount = try container.decode(Int.self, forKey: .lifetimeTripCount)
        freeTripAllowance = try container.decode(Int.self, forKey: .freeTripAllowance)
        hasActiveEntitlement = try container.decode(Bool.self, forKey: .hasActiveEntitlement)
        subscriptionVerificationPending = try container.decodeIfPresent(
            Bool.self,
            forKey: .subscriptionVerificationPending
        ) ?? false
        canCreateTrip = try container.decode(Bool.self, forKey: .canCreateTrip)
    }
}

enum TripCreationError: LocalizedError, Equatable {
    case quotaReached
    case subscriptionVerificationPending
    case authenticationRequired
    case connectivity(String)
    case serverValidation(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .quotaReached:
            return "You've used both free lifetime trip creations. Deleting a trip doesn't restore one."
        case .subscriptionVerificationPending:
            return "Your subscription still needs to be confirmed by Moss. Your draft is still here; retry verification before saving again."
        case .authenticationRequired:
            return "Moss couldn't verify your signed-in session. Your draft is still here; refresh your session or sign in again."
        case .connectivity:
            return "Moss couldn't connect to save this trip. Your draft is still here; check your connection and try again."
        case .serverValidation(let message):
            return "Moss couldn't validate this trip with the server. Your draft is still here. \(message)"
        case .unknown(let message):
            return "Moss couldn't save this trip. Your draft is still here. \(message)"
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
