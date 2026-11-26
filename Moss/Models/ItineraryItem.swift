import Foundation
import PowerSync

enum ItineraryItemKind: String, Codable, CaseIterable, Identifiable, Sendable {
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
        case .lodging: "Stay"
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

enum TransportMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case transit, driving, walking, cycling

    var id: String { rawValue }

    var label: String {
        switch self {
        case .transit: "Public transport"
        case .driving: "Driving"
        case .walking: "Walking"
        case .cycling: "Cycling"
        }
    }
}

struct TravelTimeRequest: Equatable, Identifiable, Sendable {
    let id = UUID()
    let from: String
    let to: String
    let mode: TransportMode
    let departure: Date

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.from == rhs.from && lhs.to == rhs.to && lhs.mode == rhs.mode && lhs.departure == rhs.departure
    }
}

struct ItineraryItem: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var tripID: UUID
    var ownerID: UUID
    var kind: ItineraryItemKind
    var title: String
    var locationName: String?
    var destinationName: String? = nil
    var transportMode: TransportMode? = nil
    var startsAt: Date?
    var endsAt: Date?
    var notes: String?
    var photosJSON: String? = nil
    var visitedAt: Date? = nil
    var sortOrder: Int
    var createdAt: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, kind, title, notes
        case tripID = "trip_id"
        case ownerID = "owner_id"
        case locationName = "location_name"
        case destinationName = "destination_name"
        case transportMode = "transport_mode"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case visitedAt = "visited_at"
        case photosJSON = "photos_json"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

extension ItineraryItem {
    var photos: [PlanPhoto] { PlanPhoto.decode(photosJSON) }

    var locationSummary: String? {
        guard kind == .transport else { return locationName?.nilIfBlank }
        switch (locationName?.nilIfBlank, destinationName?.nilIfBlank) {
        case let (from?, to?): return "\(from) → \(to)"
        case let (from?, nil): return "From \(from)"
        case let (nil, to?): return "To \(to)"
        case (nil, nil): return nil
        }
    }

    static func from(cursor: SqlCursor) -> ItineraryItem? {
        do {
            guard let id = UUID(uuidString: try cursor.getString(name: "id")),
                  let tripID = UUID(uuidString: try cursor.getString(name: "trip_id")),
                  let ownerID = UUID(uuidString: try cursor.getString(name: "owner_id")),
                  let kind = ItineraryItemKind(rawValue: try cursor.getString(name: "kind")) else { return nil }
            return ItineraryItem(
                id: id,
                tripID: tripID,
                ownerID: ownerID,
                kind: kind,
                title: try cursor.getString(name: "title"),
                locationName: try cursor.getStringOptional(name: "location_name"),
                destinationName: try cursor.getStringOptional(name: "destination_name"),
                transportMode: (try cursor.getStringOptional(name: "transport_mode")).flatMap(TransportMode.init(rawValue:)),
                startsAt: parseISO8601Date(try cursor.getStringOptional(name: "starts_at")),
                endsAt: parseISO8601Date(try cursor.getStringOptional(name: "ends_at")),
                notes: try cursor.getStringOptional(name: "notes"),
                photosJSON: try cursor.getStringOptional(name: "photos_json"),
                visitedAt: parseISO8601Date(try cursor.getStringOptional(name: "visited_at")),
                sortOrder: (try? cursor.getIntOptional(name: "sort_order")) ?? 0,
                createdAt: parseISO8601Date(try cursor.getStringOptional(name: "created_at")),
                updatedAt: parseISO8601Date(try cursor.getStringOptional(name: "updated_at"))
            )
        } catch {
            return nil
        }
    }
}

struct ItineraryItemDraft: Sendable {
    var kind: ItineraryItemKind = .activity
    var title = ""
    var locationName = ""
    var destinationName = ""
    var transportMode: TransportMode? = nil
    var startsAt = Date()
    var endsAt = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
    var notes = ""
    var photos: [PlanPhoto] = []

    init(startsAt: Date = Date()) {
        self.startsAt = startsAt
        endsAt = Calendar.current.date(byAdding: .hour, value: 1, to: startsAt) ?? startsAt
    }

    init(item: ItineraryItem) {
        kind = item.kind
        title = item.title
        locationName = item.locationName ?? ""
        destinationName = item.destinationName ?? ""
        transportMode = item.transportMode
        startsAt = item.startsAt ?? Date()
        endsAt = item.endsAt ?? item.startsAt ?? Date()
        notes = item.notes ?? ""
        photos = item.photos
    }

    var travelTimeRequest: TravelTimeRequest? {
        guard kind == .transport, let from = locationName.nilIfBlank,
              let to = destinationName.nilIfBlank, let transportMode else { return nil }
        return TravelTimeRequest(from: from, to: to, mode: transportMode, departure: startsAt)
    }

    mutating func applyTravelTime(_ duration: TimeInterval, for request: TravelTimeRequest) {
        guard travelTimeRequest == request, duration.isFinite, duration > 0 else { return }
        endsAt = startsAt.addingTimeInterval(duration)
    }

    var isValid: Bool {
        title.nilIfBlank != nil && endsAt >= startsAt && photos.count <= PlanPhoto.maximumCount
    }
}
