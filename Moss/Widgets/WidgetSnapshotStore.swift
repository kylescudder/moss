import Foundation

struct TodayItemSnapshot: Codable, Hashable {
    var title: String
    var symbol: String
    var startsAt: Date?
}

struct NextTripSnapshot: Codable, Hashable {
    var title: String?
    var destination: String?
    var startsAt: Date?
    var endsAt: Date?
    var todaysItems: [TodayItemSnapshot]
    var upcomingTripCount: Int
    var updatedAt: Date
}

enum WidgetSnapshotStore {
    static let appGroupID = "group.app.moss"
    static let nextTripWidgetKind = "MossNextTripWidget"

    private static let nextTripKey = "moss.widget.nextTrip"

    static func nextTrip() -> NextTripSnapshot? {
        AppGroupStore.load(NextTripSnapshot.self, forKey: nextTripKey)
    }

    static func saveNextTrip(
        title: String?,
        destination: String?,
        startsAt: Date?,
        endsAt: Date?,
        todaysItems: [TodayItemSnapshot],
        upcomingTripCount: Int
    ) {
        let snapshot = NextTripSnapshot(
            title: title,
            destination: destination,
            startsAt: startsAt,
            endsAt: endsAt,
            todaysItems: todaysItems,
            upcomingTripCount: upcomingTripCount,
            updatedAt: Date()
        )
        AppGroupStore.save(snapshot, forKey: nextTripKey)
    }
}
