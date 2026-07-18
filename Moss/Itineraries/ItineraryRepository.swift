import Foundation
import Supabase

@MainActor
final class ItineraryRepository: ObservableObject {
    @Published private(set) var itemsByTrip: [UUID: [ItineraryItem]] = [:]
    @Published private(set) var isLoading = false
    @Published var lastError: String?

    private let auth: AuthClient

    init(auth: AuthClient) {
        self.auth = auth
    }

    func reset() {
        itemsByTrip = [:]
        lastError = nil
    }

    func items(for trip: Trip) -> [ItineraryItem] {
        itemsByTrip[trip.id, default: []]
    }

    func refresh(tripID: UUID) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response: [ItineraryItem] = try await auth.supabase
                .from("itinerary_items")
                .select()
                .eq("trip_id", value: tripID.uuidString)
                .is("deleted_at", value: nil)
                .order("starts_at", ascending: true)
                .order("sort_order", ascending: true)
                .execute()
                .value
            itemsByTrip[tripID] = response
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "itinerary.refresh")
        }
    }

    func create(_ draft: ItineraryItemDraft, tripID: UUID) async -> ItineraryItem? {
        guard let userID = auth.currentUserID else { return nil }
        do {
            let payload = ItineraryItemInsert(
                tripID: tripID,
                ownerID: userID,
                kind: draft.kind,
                title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                locationName: draft.locationName.nilIfBlank,
                startsAt: draft.startsAt,
                endsAt: draft.endsAt,
                notes: draft.notes.nilIfBlank,
                sortOrder: itemsByTrip[tripID, default: []].count
            )
            let item: ItineraryItem = try await auth.supabase
                .from("itinerary_items")
                .insert(payload)
                .select()
                .single()
                .execute()
                .value
            itemsByTrip[tripID, default: []].append(item)
            itemsByTrip[tripID]?.sort(by: Self.sortItems)
            return item
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "itinerary.create")
            return nil
        }
    }

    func update(_ item: ItineraryItem) async {
        do {
            let payload = ItineraryItemUpdate(
                kind: item.kind,
                title: item.title,
                locationName: item.locationName,
                startsAt: item.startsAt,
                endsAt: item.endsAt,
                notes: item.notes,
                sortOrder: item.sortOrder
            )
            let updated: ItineraryItem = try await auth.supabase
                .from("itinerary_items")
                .update(payload)
                .eq("id", value: item.id.uuidString)
                .select()
                .single()
                .execute()
                .value
            var items = itemsByTrip[updated.tripID, default: []]
            if let index = items.firstIndex(where: { $0.id == updated.id }) {
                items[index] = updated
            }
            items.sort(by: Self.sortItems)
            itemsByTrip[updated.tripID] = items
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "itinerary.update")
        }
    }

    func softDelete(_ item: ItineraryItem) async {
        do {
            try await auth.supabase
                .from("itinerary_items")
                .update(["deleted_at": ISO8601DateFormatter().string(from: Date())])
                .eq("id", value: item.id.uuidString)
                .execute()
            itemsByTrip[item.tripID]?.removeAll { $0.id == item.id }
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "itinerary.delete")
        }
    }

    private static func sortItems(_ lhs: ItineraryItem, _ rhs: ItineraryItem) -> Bool {
        if lhs.startsAt != rhs.startsAt {
            return (lhs.startsAt ?? .distantFuture) < (rhs.startsAt ?? .distantFuture)
        }
        return lhs.sortOrder < rhs.sortOrder
    }
}

private struct ItineraryItemInsert: Encodable {
    let tripID: UUID
    let ownerID: UUID
    let kind: ItineraryItemKind
    let title: String
    let locationName: String?
    let startsAt: Date
    let endsAt: Date
    let notes: String?
    let sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case tripID = "trip_id"
        case ownerID = "owner_id"
        case kind
        case title
        case locationName = "location_name"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case notes
        case sortOrder = "sort_order"
    }
}

private struct ItineraryItemUpdate: Encodable {
    let kind: ItineraryItemKind
    let title: String
    let locationName: String?
    let startsAt: Date?
    let endsAt: Date?
    let notes: String?
    let sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case kind
        case title
        case locationName = "location_name"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case notes
        case sortOrder = "sort_order"
    }
}

