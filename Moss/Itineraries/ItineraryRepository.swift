import Combine
import Foundation
import PowerSync

/// Every itinerary item for the signed-in account, watched once and grouped
/// by trip, so the trip detail and Today screens read the same rows.
@MainActor
final class ItineraryRepository: ObservableObject {
    @Published private(set) var items: [ItineraryItem] = []
    @Published private(set) var isLoading = false
    @Published var lastError: String?

    private let database: PowerSyncDatabaseProtocol
    private var watchTask: Task<Void, Never>?
    private var userID: String?

    init(database: PowerSyncDatabaseProtocol) {
        self.database = database
    }

    deinit { watchTask?.cancel() }

    func items(for tripID: UUID) -> [ItineraryItem] {
        items.filter { $0.tripID == tripID }
    }

    /// Items starting today, across every trip.
    func todaysItems(on date: Date = Date(), calendar: Calendar = .current) -> [ItineraryItem] {
        items.filter { item in
            guard let startsAt = item.startsAt else { return false }
            return calendar.isDate(startsAt, inSameDayAs: date)
        }
    }

    func startWatching(userID: String) {
        guard self.userID != userID || watchTask == nil else { return }
        self.userID = userID
        watchTask?.cancel()
        isLoading = true
        let database = database
        watchTask = Task { [weak self] in
            do {
                let stream = try database.watch(
                    sql: Self.selectSQL,
                    parameters: [userID],
                    mapper: ItineraryItem.from(cursor:)
                )
                for try await rows in stream {
                    guard !Task.isCancelled else { return }
                    self?.items = rows.compactMap { $0 }
                    self?.isLoading = false
                }
            } catch {
                self?.isLoading = false
                Log.error(error, category: "itinerary.watch")
            }
        }
    }

    func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
        userID = nil
        items = []
        isLoading = false
        lastError = nil
    }

    func refresh() async {
        guard let userID else { return }
        do {
            let rows = try await database.getAll(
                sql: Self.selectSQL,
                parameters: [userID],
                mapper: ItineraryItem.from(cursor:)
            )
            items = rows.compactMap { $0 }
            isLoading = false
        } catch {
            Log.error(error, category: "itinerary.refresh")
        }
    }

    func create(_ draft: ItineraryItemDraft, tripID: UUID) async -> Bool {
        guard let userID else { return false }
        let now = Date().iso8601
        let sortOrder = items(for: tripID).count
        do {
            try await database.execute(
                sql: """
                insert into itinerary_items
                  (id, owner_id, trip_id, kind, title, location_name, starts_at, ends_at,
                   notes, sort_order, created_at, updated_at)
                values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                parameters: [
                    UUID().uuidString.lowercased(),
                    userID,
                    tripID.uuidString.lowercased(),
                    draft.kind.rawValue,
                    draft.title.nilIfBlank,
                    draft.locationName.nilIfBlank,
                    draft.startsAt.iso8601,
                    draft.endsAt.iso8601,
                    draft.notes.nilIfBlank,
                    sortOrder,
                    now,
                    now,
                ]
            )
            lastError = nil
            return true
        } catch {
            Log.error(error, category: "itinerary.create")
            lastError = "Moss couldn't save this item. Please try again."
            return false
        }
    }

    func update(_ item: ItineraryItem, with draft: ItineraryItemDraft) async -> Bool {
        do {
            try await database.execute(
                sql: """
                update itinerary_items set
                  kind = ?, title = ?, location_name = ?, starts_at = ?, ends_at = ?,
                  notes = ?, updated_at = ?
                where id = ?
                """,
                parameters: [
                    draft.kind.rawValue,
                    draft.title.nilIfBlank,
                    draft.locationName.nilIfBlank,
                    draft.startsAt.iso8601,
                    draft.endsAt.iso8601,
                    draft.notes.nilIfBlank,
                    Date().iso8601,
                    item.id.uuidString.lowercased(),
                ]
            )
            lastError = nil
            return true
        } catch {
            Log.error(error, category: "itinerary.update")
            lastError = "Moss couldn't save this item. Please try again."
            return false
        }
    }

    func softDelete(_ item: ItineraryItem) async {
        do {
            let now = Date().iso8601
            try await database.execute(
                sql: "update itinerary_items set deleted_at = ?, updated_at = ? where id = ?",
                parameters: [now, now, item.id.uuidString.lowercased()]
            )
        } catch {
            Log.error(error, category: "itinerary.delete")
        }
    }

    /// Items of deleted trips stay hidden until the server tombstones them.
    private static let selectSQL = """
        select itinerary_items.* from itinerary_items
        join trips on trips.id = itinerary_items.trip_id
        where itinerary_items.owner_id = ?
          and itinerary_items.deleted_at is null
          and trips.deleted_at is null
        order by itinerary_items.starts_at asc, itinerary_items.sort_order asc
        """
}
