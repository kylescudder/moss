import MapKit
import PowerSync
import XCTest
@testable import AppUnderTest

@MainActor
final class TripMapTests: XCTestCase {
    private func item(_ kind: ItineraryItemKind = .activity, location: String? = "Belém Tower") -> ItineraryItem {
        ItineraryItem(id: UUID(), tripID: UUID(), ownerID: UUID(), kind: kind, title: "Explore",
                      locationName: location, sortOrder: 0)
    }

    func testPinsIncludeBothTransportEndpointsAndOmitBlankLocations() {
        var transport = item(.transport, location: "Porto")
        transport.destinationName = "Lisbon"
        let activity = item()
        let pins = TripMapPlace.places(for: [transport, activity, item(location: "  ")])
        XCTAssertEqual(pins.map(\.location), ["Porto", "Lisbon", "Belém Tower"])
        XCTAssertEqual(Set(pins.map(\.id)).count, 3)
        XCTAssertEqual(pins.prefix(2).map(\.itemID), [transport.id, transport.id])
        transport.locationName = "Lisbon"
        XCTAssertEqual(TripMapPlace.places(for: [transport]).count, 1)
        transport.kind = .food
        transport.locationName = nil
        XCTAssertTrue(TripMapPlace.places(for: [transport]).isEmpty)
    }

    func testTravelLinesFollowPinsAndDoNotBridgeUnresolvedPlaces() {
        let places = TripMapPlace.places(for: [item(location: "A"), item(location: "B"), item(location: "C")])
        let start = CLLocationCoordinate2D(latitude: 51.5, longitude: -0.1)
        let middle = CLLocationCoordinate2D(latitude: 51.6, longitude: -0.2)
        let end = CLLocationCoordinate2D(latitude: 51.7, longitude: -0.3)
        let legs = TripMapLeg.legs(for: places, coordinates: [places[0].id: start, places[1].id: middle, places[2].id: end])
        XCTAssertEqual(legs.count, 2)
        XCTAssertEqual(legs[0].coordinates.map(\.latitude), [51.5, 51.6])
        XCTAssertEqual(legs[1].coordinates.map(\.latitude), [51.6, 51.7])
        XCTAssertTrue(TripMapLeg.legs(for: places, coordinates: [places[0].id: start, places[2].id: end]).isEmpty)
        XCTAssertTrue(TripMapLeg.legs(for: Array(places.prefix(2)), coordinates: [places[0].id: start, places[1].id: start]).isEmpty)
        XCTAssertTrue(TripMapLeg.legs(for: [], coordinates: [:]).isEmpty)
    }

    func testFailedSearchCanBeRetriedAndSuccessfulPlacesAreCached() async {
        let model = TripMapPlaces()
        let places = TripMapPlace.places(for: [item()])
        await model.load(places, destination: "Lisbon") { _, _ in nil }
        XCTAssertEqual(model.unavailable, Set([places[0].id]))
        XCTAssertFalse(model.isLoading)
        await model.load(places, destination: "Lisbon") { _, _ in CLLocationCoordinate2D(latitude: 38.69, longitude: -9.21) }
        XCTAssertTrue(model.unavailable.isEmpty)
        XCTAssertEqual(model.coordinates[places[0].id]?.latitude, 38.69)
        await model.load(places, destination: "Lisbon") { _, _ in
            XCTFail("Resolved places should be cached during this map session")
            return nil
        }
        XCTAssertEqual(model.coordinates.count, 1)
        await model.load([], destination: "Lisbon")
        XCTAssertTrue(model.coordinates.isEmpty)
    }

    func testLiveAppleMapsTripPins() async throws {
        guard ProcessInfo.processInfo.environment["MOSS_LIVE_MAPS"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_MOSS_LIVE_MAPS=1 to call Apple Maps.")
        }
        let model = TripMapPlaces()
        let places = TripMapPlace.places(for: [item(location: "British Museum, London")])
        await model.load(places, destination: "London")
        let coordinate = try XCTUnwrap(model.coordinates[places[0].id])
        XCTAssertEqual(coordinate.latitude, 51.5194, accuracy: 0.02)
        XCTAssertEqual(coordinate.longitude, -0.1270, accuracy: 0.02)
        XCTAssertTrue(model.unavailable.isEmpty)
    }

    func testCancelledSearchCannotPublishPins() async {
        let model = TripMapPlaces()
        let places = TripMapPlace.places(for: [item()])
        let task = Task {
            await model.load(places, destination: "Lisbon") { _, _ in
                try await Task.sleep(for: .seconds(10))
                return CLLocationCoordinate2D(latitude: 38, longitude: -9)
            }
        }
        await Task.yield()
        task.cancel()
        await task.value
        XCTAssertTrue(model.coordinates.isEmpty)
        XCTAssertTrue(model.unavailable.isEmpty)
        XCTAssertFalse(model.isLoading)
    }

    func testOfflineVisitToggleSurvivesReloadAndPreservesPlanEdits() async throws {
        let database = PowerSyncDatabase(schema: DatabaseSchema.schema, dbFilename: "map-tests-\(UUID()).sqlite")
        let owner = UUID()
        let trip = Trip(id: UUID(), ownerID: owner, title: "Lisbon", destination: "Portugal")
        try await database.execute(sql: "insert into trips (id, owner_id, title, destination) values (?, ?, ?, ?)",
                                   parameters: [trip.id.uuidString.lowercased(), owner.uuidString.lowercased(), trip.title, trip.destination])
        let repository = ItineraryRepository(database: database)
        repository.startWatching(userID: owner.uuidString.lowercased())
        var draft = ItineraryItemDraft()
        draft.title = "Tower"
        draft.locationName = "Belém Tower, Lisbon"
        let created = await repository.create(draft, trip: trip)
        XCTAssertTrue(created)
        await repository.refresh()
        let plan = try XCTUnwrap(repository.items.first)
        XCTAssertNil(plan.visitedAt)
        let visited = await repository.setVisited(true, for: plan)
        XCTAssertTrue(visited)
        draft.title = "Updated tower plan"
        let updated = await repository.update(plan, with: draft)
        XCTAssertTrue(updated)
        await repository.refresh()
        let reloaded = try XCTUnwrap(repository.items.first)
        XCTAssertNotNil(reloaded.visitedAt)
        XCTAssertEqual(reloaded.title, "Updated tower plan")
        XCTAssertEqual(reloaded.locationName, "Belém Tower, Lisbon")
        let undone = await repository.setVisited(false, for: reloaded)
        XCTAssertTrue(undone)
        await repository.refresh()
        XCTAssertNil(repository.items.first?.visitedAt)
        repository.stopWatching()
        try await database.close(deleteDatabase: true)
    }
}
