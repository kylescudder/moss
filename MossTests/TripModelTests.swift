import XCTest
@testable import Moss

final class TripModelTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 6, day: day, hour: 12))!
    }

    private func trip(from start: Int?, to end: Int?) -> Trip {
        Trip(
            id: UUID(),
            ownerID: UUID(),
            title: "Lisbon",
            destination: "Portugal",
            startsAt: start.map(date),
            endsAt: end.map(date)
        )
    }

    func testTripIsActiveFromItsFirstToItsLastDayInclusive() {
        let lisbon = trip(from: 10, to: 13)
        XCTAssertFalse(lisbon.isActive(on: date(9), calendar: calendar))
        XCTAssertTrue(lisbon.isActive(on: date(10), calendar: calendar))
        XCTAssertTrue(lisbon.isActive(on: date(13), calendar: calendar))
        XCTAssertFalse(lisbon.isActive(on: date(14), calendar: calendar))
        XCTAssertTrue(trip(from: 10, to: nil).isActive(on: date(10), calendar: calendar))
        XCTAssertFalse(trip(from: nil, to: nil).isActive(on: date(10), calendar: calendar))
    }

    func testDraftsRequireATitleADestinationAndOrderedDates() {
        var draft = TripDraft()
        XCTAssertFalse(draft.isValid)
        draft.title = "  Lisbon  "
        draft.destination = "Portugal"
        draft.startsAt = date(10)
        draft.endsAt = date(13)
        XCTAssertTrue(draft.isValid)
        draft.endsAt = date(9)
        XCTAssertFalse(draft.isValid)

        var item = ItineraryItemDraft(startsAt: date(10))
        XCTAssertFalse(item.isValid)
        item.title = "Tram 28"
        XCTAssertTrue(item.isValid)
        XCTAssertEqual(item.endsAt.timeIntervalSince(item.startsAt), 3600)
    }

    func testOfflineEntitlementRequiresAServerVerifiedActiveMossSubscription() {
        let now = date(10)
        let verified = OfflineEntitlementSnapshot(
            productID: BillingAppConfiguration.productID,
            bundleID: "app.getmoss.moss",
            status: "active",
            expiresAt: date(20),
            revokedAt: nil,
            environment: "Production",
            signedAt: date(1),
            verifiedAt: date(1),
            verificationSource: "device"
        )
        XCTAssertTrue(verified.isVerified(at: now))
        XCTAssertFalse(verified.isVerified(at: date(21)), "expired")

        let otherApp = OfflineEntitlementSnapshot(
            productID: BillingAppConfiguration.productID, bundleID: "club.diald", status: "active",
            expiresAt: date(20), revokedAt: nil, environment: "Production", signedAt: date(1),
            verifiedAt: date(1), verificationSource: "device"
        )
        XCTAssertFalse(otherApp.isVerified(at: now))

        let unverified = OfflineEntitlementSnapshot(
            productID: BillingAppConfiguration.productID, bundleID: "app.getmoss.moss", status: "active",
            expiresAt: date(20), revokedAt: nil, environment: "Production", signedAt: date(1),
            verifiedAt: nil, verificationSource: "device"
        )
        XCTAssertFalse(unverified.isVerified(at: now))
    }

    func testQuickActionsRouteFromMossShortcutURLs() {
        XCTAssertEqual(Set(AppQuickAction.allCases.map(\.rawValue)), ["newTrip", "today"])
        XCTAssertEqual(AppQuickAction.pendingStorageKey, "moss.pendingQuickAction")
    }
}
