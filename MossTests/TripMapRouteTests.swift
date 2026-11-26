import MapKit
import XCTest
@testable import AppUnderTest

@MainActor
final class TripMapRouteTests: XCTestCase {
    private func input(id: UUID = UUID(), mode: TransportMode = .walking, departure: Date? = nil, toLatitude: Double = 51.5117) -> TripMapRouteInput {
        TripMapRouteInput(id: id, fromLatitude: 51.5194, fromLongitude: -0.127,
                          toLatitude: toLatitude, toLongitude: -0.123, mode: mode, departure: departure)
    }

    private static func polyline() -> MKPolyline {
        let points = [CLLocationCoordinate2D(latitude: 51.5194, longitude: -0.127),
                      CLLocationCoordinate2D(latitude: 51.515, longitude: -0.129),
                      CLLocationCoordinate2D(latitude: 51.5117, longitude: -0.123)]
        return MKPolyline(coordinates: points, count: points.count)
    }

    func testOnlyCompleteTransportPlansProduceRouteInputs() {
        var transport = ItineraryItem(id: UUID(), tripID: UUID(), ownerID: UUID(), kind: .transport,
                                      title: "Train", locationName: "From", destinationName: "To",
                                      transportMode: .transit, startsAt: Date(timeIntervalSince1970: 1_800_000_000), sortOrder: 0)
        let coordinates = ["\(transport.id):from": CLLocationCoordinate2D(latitude: 51.5, longitude: -0.1),
                           "\(transport.id):to": CLLocationCoordinate2D(latitude: 51.6, longitude: -0.2)]
        let result = TripMapRouteInput.inputs(for: [transport], coordinates: coordinates)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.mode, .transit)
        XCTAssertEqual(result.first?.departure, transport.startsAt)
        XCTAssertEqual(result.first?.toLatitude, 51.6)
        XCTAssertTrue(TripMapRouteInput.inputs(for: [transport], coordinates: [:]).isEmpty)
        transport.transportMode = nil
        XCTAssertTrue(TripMapRouteInput.inputs(for: [transport], coordinates: coordinates).isEmpty)
        transport.transportMode = .walking
        transport.kind = .activity
        XCTAssertTrue(TripMapRouteInput.inputs(for: [transport], coordinates: coordinates).isEmpty)
    }

    func testAppleDirectionsRequestPreservesEndpointsModeAndDepartureWithoutFallback() {
        let modes: [(TransportMode, MKDirectionsTransportType)] = [(.transit, .transit), (.walking, .walking), (.driving, .automobile), (.cycling, .cycling)]
        let departure = Date(timeIntervalSince1970: 1_800_000_000)
        for (mode, expectedType) in modes {
            let request = AppleMapsTripRouting.request(for: input(mode: mode, departure: departure))
            XCTAssertEqual(request.source?.placemark.coordinate.latitude, 51.5194)
            XCTAssertEqual(request.destination?.placemark.coordinate.longitude, -0.123)
            XCTAssertEqual(request.transportType, expectedType)
            XCTAssertEqual(request.departureDate, departure)
            XCTAssertFalse(request.requestsAlternateRoutes)
        }
    }

    func testReturnedGeometryIsCachedAndModeChangesRequestANewRoute() async {
        let provider = RouteFixture()
        provider.result = Self.polyline()
        let model = TripMapRoutes(provider: provider)
        let first = input()
        await model.load([first])
        XCTAssertTrue(model.polylines[first.id] === provider.result)
        XCTAssertEqual(model.polylines[first.id]?.pointCount, 3)
        await model.load([])
        XCTAssertTrue(model.polylines.isEmpty)
        await model.load([first])
        XCTAssertEqual(provider.requests.count, 1)
        let changed = input(id: first.id, mode: .driving)
        await model.load([changed])
        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertEqual(provider.requests.last?.mode, .driving)
        await model.load([input(id: first.id, mode: .driving, departure: Date(timeIntervalSince1970: 1_800_000_000))])
        await model.load([input(id: first.id, mode: .driving, toLatitude: 51.52)])
        XCTAssertEqual(provider.requests.count, 4, "Departure and endpoint edits invalidate the cached route")
    }

    func testUnavailableRouteDoesNotDrawAStraightLineAndCanBeRetried() async {
        let provider = RouteFixture()
        let model = TripMapRoutes(provider: provider)
        let request = input(mode: .transit)
        await model.load([request])
        XCTAssertTrue(model.polylines.isEmpty)
        XCTAssertEqual(model.unavailable, [request.id])
        XCTAssertFalse(model.isLoading)
        provider.shouldFail = true
        await model.load([request])
        XCTAssertTrue(model.polylines.isEmpty)
        XCTAssertEqual(model.unavailable, [request.id])
        provider.shouldFail = false
        provider.result = Self.polyline()
        await model.load([request])
        XCTAssertTrue(model.unavailable.isEmpty)
        XCTAssertEqual(model.polylines[request.id]?.pointCount, 3)
    }

    func testCancelledRouteCannotPublishGeometryOrAnError() async {
        let provider = RouteFixture()
        provider.delay = true
        let model = TripMapRoutes(provider: provider)
        let pending = Task { await model.load([input()]) }
        await Task.yield()
        pending.cancel()
        await pending.value
        XCTAssertTrue(model.polylines.isEmpty)
        XCTAssertTrue(model.unavailable.isEmpty)
        XCTAssertFalse(model.isLoading)
    }

    func testLateRouteCannotReappearAfterRoutesAreHidden() async {
        let provider = RouteFixture()
        provider.suspend = true
        let model = TripMapRoutes(provider: provider)
        let request = input()
        let pending = Task { await model.load([request]) }
        let deadline = Date().addingTimeInterval(2)
        while provider.pending == nil, Date() < deadline { await Task.yield() }
        guard let continuation = provider.pending else {
            pending.cancel()
            XCTFail("Route never reached provider")
            await pending.value
            return
        }
        await model.load([])
        continuation.resume(returning: Self.polyline())
        await pending.value
        XCTAssertTrue(model.polylines.isEmpty)
        XCTAssertTrue(model.unavailable.isEmpty)
        XCTAssertFalse(model.isLoading)
    }

    func testLiveAppleMapsReturnsWalkingRouteGeometry() async throws {
        guard ProcessInfo.processInfo.environment["MOSS_LIVE_MAPS"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_MOSS_LIVE_MAPS=1 to call Apple Maps.")
        }
        let model = TripMapRoutes()
        let request = input()
        await model.load([request])
        let route = try XCTUnwrap(model.polylines[request.id])
        XCTAssertGreaterThan(route.pointCount, 2, "Use Apple Maps road/path geometry, never a two-point connector")
        XCTAssertTrue(model.unavailable.isEmpty)
    }
}

@MainActor
private final class RouteFixture: TripMapRouting {
    var result: MKPolyline?
    var requests: [TripMapRouteInput] = []
    var delay = false
    var shouldFail = false
    var suspend = false
    var pending: CheckedContinuation<MKPolyline?, Never>?

    func route(for input: TripMapRouteInput) async throws -> MKPolyline? {
        requests.append(input)
        if delay { try await Task.sleep(for: .seconds(10)) }
        if shouldFail { throw URLError(.notConnectedToInternet) }
        if suspend { return await withCheckedContinuation { pending = $0 } }
        return result
    }
}
