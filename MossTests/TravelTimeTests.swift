import MapKit
import XCTest
@testable import AppUnderTest

@MainActor
final class TravelTimeTests: XCTestCase {
    private let departure = Date(timeIntervalSince1970: 1_800_316_200) // A fixed instant; tests don't depend on the local timezone.

    private func request(mode: TransportMode = .transit) -> TravelTimeRequest {
        TravelTimeRequest(from: "Porto", to: "Lisbon", mode: mode, departure: departure)
    }

    func testEveryModeUsesTheRequestedMapKitTransportType() {
        XCTAssertEqual(TransportMode.transit.mapKitType, .transit)
        XCTAssertEqual(TransportMode.driving.mapKitType, .automobile)
        XCTAssertEqual(TransportMode.walking.mapKitType, .walking)
        XCTAssertEqual(TransportMode.cycling.mapKitType, .cycling)
    }

    func testEstimateRequiresBothPlacesAndAModeAndOnlyAppliesToTheSameDraft() {
        var draft = ItineraryItemDraft(startsAt: departure)
        draft.kind = .transport
        draft.locationName = "Porto"
        draft.destinationName = "Lisbon"
        XCTAssertNil(draft.travelTimeRequest)
        draft.transportMode = .walking
        let original = draft.travelTimeRequest!
        draft.applyTravelTime(90 * 60, for: original)
        XCTAssertEqual(draft.endsAt, departure.addingTimeInterval(5400))

        draft.startsAt = departure.addingTimeInterval(3600)
        let previousEnd = draft.endsAt
        draft.applyTravelTime(60, for: original)
        XCTAssertEqual(draft.endsAt, previousEnd, "A result for an earlier departure must not change the plan.")
        draft.startsAt = departure
        draft.transportMode = .driving
        draft.applyTravelTime(60, for: original)
        XCTAssertEqual(draft.endsAt, previousEnd, "A result for a different mode must not change the plan.")
        draft.destinationName = " "
        XCTAssertNil(draft.travelTimeRequest)
        draft.destinationName = "Lisbon"
        draft.kind = .food
        XCTAssertNil(draft.travelTimeRequest)
    }

    func testEstimateRoundsUpAndCalculatesArrivalAcrossMidnight() async {
        let provider = TravelTimeFixture()
        provider.seconds = 901
        let start = ISO8601DateFormatter().date(from: "2026-11-25T23:55:00Z")!
        let input = TravelTimeRequest(from: "Porto", to: "Lisbon", mode: .driving, departure: start)
        let model = TransportTravelTime(request: input, provider: provider)
        await model.loadPlaces()
        await model.calculate()
        XCTAssertEqual(model.duration, 960)
        XCTAssertEqual(model.arrival, ISO8601DateFormatter().date(from: "2026-11-26T00:11:00Z"))
        XCTAssertEqual(provider.receivedRequest, input)
    }

    func testUnavailablePlacesOrRoutesLeaveManualTimesUntouchedAndAllowRetry() async {
        let provider = TravelTimeFixture()
        provider.matches = []
        let model = TransportTravelTime(request: request(), provider: provider)
        await model.loadPlaces()
        XCTAssertFalse(model.canCalculate)
        XCTAssertNotNil(model.errorMessage)

        provider.matches = [TravelTimeFixture.place("Station")]
        await model.loadPlaces()
        XCTAssertTrue(model.canCalculate)
        provider.shouldFail = true
        await model.calculate()
        XCTAssertNil(model.duration)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.canCalculate)

        provider.shouldFail = false
        await model.calculate()
        XCTAssertNotNil(model.duration)
        XCTAssertNil(model.errorMessage)
    }

    func testChangingMatchedPlaceDiscardsAnEstimateInFlight() async {
        let provider = TravelTimeFixture()
        provider.matches = [TravelTimeFixture.place("First"), TravelTimeFixture.place("Second")]
        provider.suspendCalculation = true
        let model = TransportTravelTime(request: request(), provider: provider)
        await model.loadPlaces()
        let pending = Task { await model.calculate() }
        let deadline = Date().addingTimeInterval(2)
        while provider.pending == nil, Date() < deadline { await Task.yield() }
        guard provider.pending != nil else {
            XCTFail("The estimate never reached the provider.")
            await pending.value
            return
        }
        model.destinationIndex = 1
        provider.pending?.resume(returning: 600)
        await pending.value
        XCTAssertNil(model.duration)
        XCTAssertFalse(model.isCalculating)
        XCTAssertTrue(model.canCalculate)
    }

    func testInvalidDurationIsNotOfferedForUse() async {
        let provider = TravelTimeFixture()
        let model = TransportTravelTime(request: request(), provider: provider)
        await model.loadPlaces()
        for seconds in [0, -1, TimeInterval.infinity, TimeInterval.nan] {
            provider.seconds = seconds
            await model.calculate()
            XCTAssertNil(model.duration)
            XCTAssertNotNil(model.errorMessage)
        }
    }

    /// Opt-in smoke coverage against Apple's real service; normal runs remain offline.
    func testLiveAppleMapsEstimates() async throws {
        guard ProcessInfo.processInfo.environment["MOSS_LIVE_MAPS"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_MOSS_LIVE_MAPS=1 to call Apple Maps.")
        }
        let provider = AppleMapsTravelTime()
        let origins = try await provider.places(matching: "London Waterloo station, London, UK")
        let destinations = try await provider.places(matching: "London Victoria station, London, UK")
        let from = try XCTUnwrap(origins.first)
        let to = try XCTUnwrap(destinations.first)
        for mode in TransportMode.allCases {
            let input = TravelTimeRequest(from: "Waterloo", to: "Victoria", mode: mode, departure: Date().addingTimeInterval(3600))
            let duration = try await provider.duration(from: from, to: to, request: input)
            XCTAssertTrue(duration.isFinite && duration > 0, mode.label)
        }
    }
}

@MainActor
private final class TravelTimeFixture: TravelTimeProviding {
    var matches = [place("Station")]
    var seconds: TimeInterval = 1200
    var shouldFail = false
    var suspendCalculation = false
    var pending: CheckedContinuation<TimeInterval, Never>?
    var receivedRequest: TravelTimeRequest?

    static func place(_ name: String) -> MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: 51.5, longitude: -0.1)))
        item.name = name
        return item
    }

    func places(matching query: String) async throws -> [MKMapItem] {
        matches
    }

    func duration(from: MKMapItem, to: MKMapItem, request: TravelTimeRequest) async throws -> TimeInterval {
        receivedRequest = request
        if shouldFail { throw URLError(.notConnectedToInternet) }
        if suspendCalculation {
            return await withCheckedContinuation { pending = $0 }
        }
        return seconds
    }
}
