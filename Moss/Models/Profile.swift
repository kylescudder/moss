import Foundation
import PowerSync

struct Profile: Codable, Identifiable, Equatable {
    let id: UUID
    var displayName: String?
    var createdAt: Date?
    var updatedAt: Date?
    var deletedAt: Date? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

extension Profile {
    static func from(cursor: SqlCursor) -> Profile? {
        do {
            guard let id = UUID(uuidString: try cursor.getString(name: "id")) else { return nil }
            return Profile(id: id, displayName: try cursor.getStringOptional(name: "display_name"),
                createdAt: parseISO8601Date(try cursor.getStringOptional(name: "created_at")),
                updatedAt: parseISO8601Date(try cursor.getStringOptional(name: "updated_at")),
                deletedAt: parseISO8601Date(try cursor.getStringOptional(name: "deleted_at")))
        } catch { return nil }
    }
}
