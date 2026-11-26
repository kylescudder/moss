import MapKit
import XCTest
@testable import AppUnderTest

@MainActor
final class LocationSearchTests: XCTestCase {
    func testSearchIncludesAddressesAndBusinesses() throws {
        let search = LocationSearch()
        search.search("  London Waterloo  ")
        let completer = try XCTUnwrap(search.completer)
        XCTAssertEqual(completer.queryFragment, "London Waterloo")
        XCTAssertEqual(completer.resultTypes, [.address, .pointOfInterest])
        XCTAssertTrue(search.isSearching)
        search.cancel()
    }

    func testSupersededAndCancelledQueriesCannotPublishErrors() throws {
        let search = LocationSearch()
        search.search("London")
        let old = try XCTUnwrap(search.completer)
        search.search("Paris")
        search.receiveFailure(URLError(.notConnectedToInternet), from: ObjectIdentifier(old))
        search.receive([], from: ObjectIdentifier(old))
        XCTAssertTrue(search.isSearching)
        XCTAssertNil(search.message)
        let current = try XCTUnwrap(search.completer)
        search.cancel()
        search.receiveFailure(URLError(.notConnectedToInternet), from: ObjectIdentifier(current))
        XCTAssertNil(search.message)
        XCTAssertFalse(search.isSearching)
        XCTAssertTrue(search.results.isEmpty)
    }

    func testFailureAllowsRetryAndBlankTextClearsSearch() throws {
        let search = LocationSearch()
        search.search("London")
        let completer = try XCTUnwrap(search.completer)
        search.receiveFailure(URLError(.notConnectedToInternet), from: ObjectIdentifier(completer))
        XCTAssertNotNil(search.message)
        XCTAssertFalse(search.isSearching)
        search.search("Paris")
        XCTAssertNil(search.message)
        XCTAssertTrue(search.isSearching)
        search.search(" \n ")
        XCTAssertNil(search.completer)
        XCTAssertFalse(search.isSearching)
        XCTAssertTrue(search.results.isEmpty)
    }

    func testResultsAndEmptyStateBelongToCurrentQuery() throws {
        let search = LocationSearch()
        search.search("London")
        let completer = try XCTUnwrap(search.completer)
        let places = [LocationSuggestion(title: "Café", subtitle: "London")]
        search.receive(places, from: ObjectIdentifier(completer))
        XCTAssertEqual(search.results, places)
        XCTAssertFalse(search.isSearching)
        XCTAssertNil(search.message)
        search.receive([], from: ObjectIdentifier(completer))
        XCTAssertTrue(search.results.isEmpty)
        XCTAssertNotNil(search.message)
        search.cancel()
    }

    func testLiveAppleMapsAddressAndBusinessSuggestions() async throws {
        guard ProcessInfo.processInfo.environment["MOSS_LIVE_MAPS"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_MOSS_LIVE_MAPS=1 to call Apple Maps.")
        }
        let search = LocationSearch()
        defer { search.cancel() }
        for query in ["10 Downing Street London", "British Museum London"] {
            search.search(query)
            let deadline = Date().addingTimeInterval(20)
            while search.isSearching, Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertFalse(search.isSearching, query)
            XCTAssertFalse(search.results.isEmpty, query)
            XCTAssertNil(search.message, query)
        }
    }

    func testSelectedTextRetainsAddressWithoutDuplicatingIdenticalParts() {
        let text = LocationSearch.locationText(title: "Café", subtitle: "1 High Street, London")
        XCTAssertEqual(text, "Café, 1 High Street, London")
        XCTAssertEqual(LocationSearch.locationText(title: "London", subtitle: "London"), "London")
        XCTAssertEqual(LocationSearch.locationText(title: "10 Downing Street", subtitle: ""), "10 Downing Street")
    }
}
