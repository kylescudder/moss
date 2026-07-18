import Foundation

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

