import Foundation

/// A trip as the widget needs it.
struct WidgetTrip: Codable, Hashable {
    var title: String
    var destination: String
    var startsAt: Date?
    var endsAt: Date?

    func isActive(on date: Date, calendar: Calendar = .current) -> Bool {
        guard let startsAt else { return false }
        let day = calendar.startOfDay(for: date)
        return calendar.startOfDay(for: startsAt) <= day
            && day <= calendar.startOfDay(for: endsAt ?? startsAt)
    }
}

/// A dated itinerary item as the widget needs it.
struct WidgetItem: Codable, Hashable {
    var title: String
    var symbol: String
    var startsAt: Date
}

/// Dated data, not a rendered day: the widget derives "current or next trip"
/// and "today" for each timeline entry, so it stays correct after midnight
/// while the app is closed.
struct NextTripSnapshot: Codable, Hashable {
    /// Current and upcoming trips, soonest first.
    var trips: [WidgetTrip]
    /// Items from the day of publishing through `itemHorizonDays` ahead.
    var items: [WidgetItem]
    var updatedAt: Date

    /// The trip under way on `date`, else the next one to start.
    func focusTrip(on date: Date, calendar: Calendar = .current) -> WidgetTrip? {
        let day = calendar.startOfDay(for: date)
        return trips.first { $0.isActive(on: date, calendar: calendar) }
            ?? trips.first { trip in
                trip.startsAt.map { calendar.startOfDay(for: $0) > day } ?? false
            }
    }

    func items(on date: Date, calendar: Calendar = .current) -> [WidgetItem] {
        items.filter { calendar.isDate($0.startsAt, inSameDayAs: date) }
    }

    /// Whether the snapshot still covers `date`. Past the horizon, "nothing
    /// today" could be wrong, so the widget asks the user to open Moss.
    func covers(_ date: Date, calendar: Calendar = .current) -> Bool {
        let last = calendar.date(
            byAdding: .day,
            value: WidgetSnapshotStore.itemHorizonDays,
            to: calendar.startOfDay(for: updatedAt)
        ) ?? updatedAt
        return calendar.startOfDay(for: date) <= last
    }
}

enum WidgetSnapshotStore {
    static let appGroupID = "group.app.moss"
    static let nextTripWidgetKind = "MossNextTripWidget"
    /// How many days of plans a snapshot carries beyond the publishing day.
    static let itemHorizonDays = 14

    private static let nextTripKey = "moss.widget.nextTrip.v2"

    static func nextTrip() -> NextTripSnapshot? {
        AppGroupStore.load(NextTripSnapshot.self, forKey: nextTripKey)
    }

    static func saveNextTrip(trips: [WidgetTrip], items: [WidgetItem], now: Date = Date()) {
        AppGroupStore.save(NextTripSnapshot(trips: trips, items: items, updatedAt: now), forKey: nextTripKey)
    }
}
