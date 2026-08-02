import Foundation
import PowerSync

struct Trip: Codable, Identifiable, Equatable {
    let id: UUID
    var ownerID: UUID
    var title: String
    var destination: String
    var startsAt: Date?
    var endsAt: Date?
    var notes: String?
    var createdAt: Date?
    var updatedAt: Date?
    var deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case ownerID = "owner_id"
        case title
        case destination
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case notes
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

extension Trip {
    static func from(cursor: SqlCursor) -> Trip? {
        do {
            guard let id = UUID(uuidString: try cursor.getString(name: "id")),
                  let ownerID = UUID(uuidString: try cursor.getString(name: "owner_id")) else { return nil }
            return Trip(id: id, ownerID: ownerID, title: try cursor.getString(name: "title"),
                destination: try cursor.getString(name: "destination"),
                startsAt: parseISO8601Date(try cursor.getStringOptional(name: "starts_at")),
                endsAt: parseISO8601Date(try cursor.getStringOptional(name: "ends_at")),
                notes: try cursor.getStringOptional(name: "notes"),
                createdAt: parseISO8601Date(try cursor.getStringOptional(name: "created_at")),
                updatedAt: parseISO8601Date(try cursor.getStringOptional(name: "updated_at")),
                deletedAt: parseISO8601Date(try cursor.getStringOptional(name: "deleted_at")))
        } catch { return nil }
    }
}

struct TripDraft {
    var title = ""
    var destination = ""
    var startsAt = Date()
    var endsAt = Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date()
    var notes = ""

    var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
