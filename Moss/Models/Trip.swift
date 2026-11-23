import Foundation
import PowerSync

struct Trip: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var ownerID: UUID
    var title: String
    var destination: String
    var startsAt: Date?
    var endsAt: Date?
    var notes: String?
    var createdAt: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, title, destination, notes
        case ownerID = "owner_id"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// The trip is under way today.
    func isActive(on date: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let startsAt else { return false }
        let start = calendar.startOfDay(for: startsAt)
        let end = calendar.startOfDay(for: endsAt ?? startsAt)
        let day = calendar.startOfDay(for: date)
        return start <= day && day <= end
    }
}

extension Trip {
    static func from(cursor: SqlCursor) -> Trip? {
        do {
            guard let id = UUID(uuidString: try cursor.getString(name: "id")),
                  let ownerID = UUID(uuidString: try cursor.getString(name: "owner_id")) else { return nil }
            return Trip(
                id: id,
                ownerID: ownerID,
                title: try cursor.getString(name: "title"),
                destination: try cursor.getString(name: "destination"),
                startsAt: parseISO8601Date(try cursor.getStringOptional(name: "starts_at")),
                endsAt: parseISO8601Date(try cursor.getStringOptional(name: "ends_at")),
                notes: try cursor.getStringOptional(name: "notes"),
                createdAt: parseISO8601Date(try cursor.getStringOptional(name: "created_at")),
                updatedAt: parseISO8601Date(try cursor.getStringOptional(name: "updated_at"))
            )
        } catch {
            return nil
        }
    }
}

struct TripDraft: Sendable {
    var title = ""
    var destination = ""
    var startsAt = Date()
    var endsAt = Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date()
    var notes = ""

    init() {}

    init(trip: Trip) {
        title = trip.title
        destination = trip.destination
        startsAt = trip.startsAt ?? Date()
        endsAt = trip.endsAt ?? trip.startsAt ?? Date()
        notes = trip.notes ?? ""
    }

    var isValid: Bool {
        title.nilIfBlank != nil && destination.nilIfBlank != nil && endsAt >= startsAt
    }
}
