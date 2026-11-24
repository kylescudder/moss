import Foundation
import PowerSync

struct Profile: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var username: String?
    var displayName: String?
    var isPremiumAccount: Bool = false
    var createdAt: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, username
        case displayName = "display_name"
        case isPremiumAccount = "is_premium_account"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

extension Profile {
    static func from(cursor: SqlCursor) -> Profile? {
        do {
            guard let id = UUID(uuidString: try cursor.getString(name: "id")) else { return nil }
            return Profile(
                id: id,
                username: try cursor.getStringOptional(name: "username"),
                displayName: try cursor.getStringOptional(name: "display_name"),
                isPremiumAccount: (try? cursor.getInt(name: "is_premium_account")) == 1,
                createdAt: parseISO8601Date(try cursor.getStringOptional(name: "created_at")),
                updatedAt: parseISO8601Date(try cursor.getStringOptional(name: "updated_at"))
            )
        } catch {
            return nil
        }
    }
}
