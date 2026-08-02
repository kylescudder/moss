import Foundation
import PowerSync

enum ItineraryItemKind: String, Codable, CaseIterable, Identifiable {
    case flight
    case lodging
    case food
    case activity
    case transport
    case note

    var id: String { rawValue }

    var label: String {
        switch self {
        case .flight: "Flight"
        case .lodging: "Lodging"
        case .food: "Food"
        case .activity: "Activity"
        case .transport: "Transport"
        case .note: "Note"
        }
    }

    var symbol: String {
        switch self {
        case .flight: "airplane"
        case .lodging: "bed.double.fill"
        case .food: "fork.knife"
        case .activity: "figure.walk"
        case .transport: "tram.fill"
        case .note: "note.text"
        }
    }
}

extension ItineraryItem {
    static func from(cursor: SqlCursor) -> ItineraryItem? {
        do {
            guard let id = UUID(uuidString: try cursor.getString(name: "id")),
                  let tripID = UUID(uuidString: try cursor.getString(name: "trip_id")),
                  let ownerID = UUID(uuidString: try cursor.getString(name: "owner_id")),
                  let kind = ItineraryItemKind(rawValue: try cursor.getString(name: "kind")) else { return nil }
            return ItineraryItem(id: id, tripID: tripID, ownerID: ownerID, kind: kind,
                title: try cursor.getString(name: "title"), locationName: try cursor.getStringOptional(name: "location_name"),
                startsAt: parseISO8601Date(try cursor.getStringOptional(name: "starts_at")),
                endsAt: parseISO8601Date(try cursor.getStringOptional(name: "ends_at")), notes: try cursor.getStringOptional(name: "notes"),
                sortOrder: try cursor.getInt(name: "sort_order"), createdAt: parseISO8601Date(try cursor.getStringOptional(name: "created_at")),
                updatedAt: parseISO8601Date(try cursor.getStringOptional(name: "updated_at")), deletedAt: parseISO8601Date(try cursor.getStringOptional(name: "deleted_at")))
        } catch { return nil }
    }
}

struct ItineraryItem: Codable, Identifiable, Equatable {
    let id: UUID
    var tripID: UUID
    var ownerID: UUID
    var kind: ItineraryItemKind
    var title: String
    var locationName: String?
    var startsAt: Date?
    var endsAt: Date?
    var notes: String?
    var sortOrder: Int
    var createdAt: Date?
    var updatedAt: Date?
    var deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case tripID = "trip_id"
        case ownerID = "owner_id"
        case kind
        case title
        case locationName = "location_name"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case notes
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

struct ItineraryItemDraft {
    var kind: ItineraryItemKind = .activity
    var title = ""
    var locationName = ""
    var startsAt = Date()
    var endsAt = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
    var notes = ""

    var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
