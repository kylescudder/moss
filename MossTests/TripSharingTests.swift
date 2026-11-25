import Foundation
import PowerSync
import XCTest
@testable import AppUnderTest

/// Moss's side of sharing: trips shared one at a time or through someone's
/// library appear locally with their plans, plans added to a shared trip
/// belong to its owner, and shared rows never confuse offline ownership.
@MainActor
final class TripSharingTests: XCTestCase {
    private var databases: [PowerSyncDatabaseProtocol] = []
    private let me = UUID().uuidString.lowercased()
    private let friend = UUID().uuidString.lowercased()
    private let stranger = UUID().uuidString.lowercased()

    override func tearDown() async throws {
        for database in databases {
            try? await database.close(deleteDatabase: true)
        }
        databases = []
        try await super.tearDown()
    }

    func testOwnSharedAndLibraryTripsAreListedButOthersAreNot() async throws {
        let database = makeDatabase()
        let own = try await insertTrip(database, owner: me, title: "Own")
        let single = try await insertTrip(database, owner: friend, title: "Single")
        let library = try await insertTrip(database, owner: stranger, title: "Library")
        _ = try await insertTrip(database, owner: friend, title: "Not shared")
        let deleted = try await insertTrip(database, owner: me, title: "Deleted")
        try await database.execute(sql: "update trips set deleted_at = ? where id = ?", parameters: ["2026-11-23T10:00:00Z", deleted])
        try await insertMember(database, table: "trip_members", column: "trip_id", space: single, user: me, role: "viewer")
        try await insertMember(database, table: "library_members", column: "library_id", space: stranger, user: me, role: "editor")

        let auth = try makeAuth()
        let trips = TripsRepository(auth: auth, billing: BillingRepository(auth: auth), database: database)
        trips.startWatching(userID: me)
        try await waitUntil { trips.trips.count == 3 }
        XCTAssertEqual(Set(trips.trips.map { $0.id.uuidString.lowercased() }), [own, single, library])

        for (tripID, owner) in [(own, me), (single, friend), (library, stranger)] {
            try await insertItem(database, trip: tripID, owner: owner)
        }
        let itinerary = ItineraryRepository(database: database)
        itinerary.startWatching(userID: me)
        try await waitUntil { itinerary.items.count == 3 }
    }

    func testPlansAddedToASharedTripBelongToItsOwner() async throws {
        let database = makeDatabase()
        let tripID = try await insertTrip(database, owner: friend, title: "Shared")
        try await insertMember(database, table: "trip_members", column: "trip_id", space: tripID, user: me, role: "editor")
        let itinerary = ItineraryRepository(database: database)
        itinerary.startWatching(userID: me)
        let trip = Trip(id: try XCTUnwrap(UUID(uuidString: tripID)), ownerID: try XCTUnwrap(UUID(uuidString: friend)), title: "Shared", destination: "Porto")
        var draft = ItineraryItemDraft()
        draft.title = "Dinner"

        let saved = await itinerary.create(draft, trip: trip)

        XCTAssertTrue(saved)
        let owners = try await database.getAll(sql: "select owner_id from itinerary_items", parameters: [], mapper: { try $0.getString(name: "owner_id") })
        XCTAssertEqual(owners, [friend])
    }

    func testSharedTripsNeverCountAsAnotherOfflineOwner() async throws {
        let database = makeDatabase()
        try await database.execute(sql: "insert into profiles (id) values (?)", parameters: [me])
        // My trip, shared with a friend.
        let mine = try await insertTrip(database, owner: me, title: "Mine")
        try await insertMember(database, table: "trip_members", column: "trip_id", space: mine, user: me, role: "owner")
        try await insertMember(database, table: "trip_members", column: "trip_id", space: mine, user: friend, role: "editor")
        // A friend's trip shared with me, and a stranger's library.
        let theirs = try await insertTrip(database, owner: friend, title: "Theirs")
        try await insertMember(database, table: "trip_members", column: "trip_id", space: theirs, user: friend, role: "owner")
        try await insertMember(database, table: "trip_members", column: "trip_id", space: theirs, user: me, role: "viewer")
        try await insertItem(database, trip: theirs, owner: friend)
        let library = try await insertTrip(database, owner: stranger, title: "Library")
        try await insertMember(database, table: "library_members", column: "library_id", space: stranger, user: stranger, role: "owner")
        try await insertMember(database, table: "library_members", column: "library_id", space: stranger, user: me, role: "viewer")
        try await insertItem(database, trip: library, owner: stranger)

        let owners = try await database.getAll(
            sql: SyncAppConfiguration.offlineOwnerQuery,
            parameters: [],
            mapper: { try $0.getString(name: "id") }
        )

        XCTAssertEqual(Set(owners), [me])
    }

    func testTransportRouteSurvivesCreationEditingAndChangingKind() async throws {
        let database = makeDatabase()
        let tripID = try await insertTrip(database, owner: me, title: "Porto")
        let trip = Trip(id: try XCTUnwrap(UUID(uuidString: tripID)), ownerID: try XCTUnwrap(UUID(uuidString: me)), title: "Porto", destination: "Portugal")
        let itinerary = ItineraryRepository(database: database)
        itinerary.startWatching(userID: me)
        defer { itinerary.stopWatching() }
        var draft = ItineraryItemDraft()
        draft.kind = .transport
        draft.transportMode = .transit
        draft.title = "Train"
        draft.locationName = "  Porto Campanhã  "
        draft.destinationName = "  Lisboa Oriente  "

        let created = await itinerary.create(draft, trip: trip)
        XCTAssertTrue(created)
        try await waitUntil { itinerary.items.count == 1 }
        let item = try XCTUnwrap(itinerary.items.first)
        XCTAssertEqual(item.transportMode, .transit)
        XCTAssertEqual(item.locationName, "Porto Campanhã")
        XCTAssertEqual(item.destinationName, "Lisboa Oriente")
        XCTAssertEqual(item.locationSummary, "Porto Campanhã → Lisboa Oriente")

        var edited = ItineraryItemDraft(item: item)
        XCTAssertEqual(edited.destinationName, "Lisboa Oriente")
        edited.destinationName = "Coimbra"
        edited.transportMode = .driving
        let updated = await itinerary.update(item, with: edited)
        XCTAssertTrue(updated)
        try await waitUntil { itinerary.items.first?.destinationName == "Coimbra" }

        XCTAssertEqual(itinerary.items.first?.transportMode, .driving)
        edited.kind = .activity
        let changedKind = await itinerary.update(item, with: edited)
        XCTAssertTrue(changedKind)
        try await waitUntil { itinerary.items.first?.kind == .activity }
        XCTAssertNil(itinerary.items.first?.destinationName)
        XCTAssertNil(itinerary.items.first?.transportMode)
        XCTAssertEqual(itinerary.items.first?.locationSummary, "Porto Campanhã")
    }

    // MARK: Helpers

    private func makeDatabase() -> PowerSyncDatabaseProtocol {
        let database = PowerSyncDatabase(schema: DatabaseSchema.schema, dbFilename: "trip-sharing-\(UUID().uuidString).sqlite")
        databases.append(database)
        return database
    }

    private func makeAuth() throws -> AuthClient {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        return AuthClient(sessionStore: TripSharingSessionStore(), defaults: defaults, api: APIClient())
    }

    @discardableResult
    private func insertTrip(_ database: PowerSyncDatabaseProtocol, owner: String, title: String) async throws -> String {
        let id = UUID().uuidString.lowercased()
        try await database.execute(
            sql: "insert into trips (id, owner_id, title, destination, starts_at, created_at) values (?, ?, ?, 'Porto', ?, ?)",
            parameters: [id, owner, title, "2026-12-01T09:00:00Z", "2026-11-23T10:00:00Z"]
        )
        return id
    }

    private func insertItem(_ database: PowerSyncDatabaseProtocol, trip: String, owner: String) async throws {
        try await database.execute(
            sql: "insert into itinerary_items (id, owner_id, trip_id, kind, title, starts_at, sort_order) values (?, ?, ?, 'note', 'Plan', ?, 0)",
            parameters: [UUID().uuidString.lowercased(), owner, trip, "2026-12-01T10:00:00Z"]
        )
    }

    private func insertMember(_ database: PowerSyncDatabaseProtocol, table: String, column: String, space: String, user: String, role: String) async throws {
        try await database.execute(
            sql: "insert into \(table) (id, \(column), user_id, role, joined_at) values (?, ?, ?, ?, ?)",
            parameters: ["\(space):\(user)", space, user, role, "2026-11-23T10:00:00Z"]
        )
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for the watch")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

@MainActor
private final class TripSharingSessionStore: SessionStore {
    func read() throws -> Data? { nil }
    func write(_ data: Data?) throws {}
}
