import Combine
import XCTest
@testable import AppUnderTest

final class WidgetSnapshotTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private func date(_ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 6, day: day, hour: hour))!
    }

    private var snapshot: NextTripSnapshot {
        NextTripSnapshot(
            trips: [
                WidgetTrip(title: "Lisbon", destination: "Portugal", startsAt: date(10), endsAt: date(11)),
                WidgetTrip(title: "Kyoto", destination: "Japan", startsAt: date(15), endsAt: date(20)),
            ],
            items: [
                WidgetItem(title: "Tram 28", symbol: "tram.fill", startsAt: date(10, hour: 9)),
                WidgetItem(title: "Pastéis", symbol: "fork.knife", startsAt: date(11, hour: 10)),
            ],
            updatedAt: date(10, hour: 8)
        )
    }

    func testEachDayDerivesItsOwnTripAndPlansAfterMidnight() {
        XCTAssertEqual(snapshot.focusTrip(on: date(10), calendar: calendar)?.title, "Lisbon")
        XCTAssertEqual(snapshot.items(on: date(10), calendar: calendar).map(\.title), ["Tram 28"])

        // The next morning: yesterday's plan is no longer "today".
        XCTAssertEqual(snapshot.items(on: date(11, hour: 0), calendar: calendar).map(\.title), ["Pastéis"])

        // Once Lisbon has ended the widget moves on to the next trip.
        XCTAssertEqual(snapshot.focusTrip(on: date(12), calendar: calendar)?.title, "Kyoto")
        XCTAssertTrue(snapshot.items(on: date(12), calendar: calendar).isEmpty)

        // After the last trip there is nothing to show.
        XCTAssertNil(snapshot.focusTrip(on: date(21), calendar: calendar))
    }

    func testSnapshotStopsCoveringDaysPastItsItemHorizon() {
        let horizon = WidgetSnapshotStore.itemHorizonDays
        XCTAssertTrue(snapshot.covers(date(10 + horizon), calendar: calendar))
        XCTAssertFalse(snapshot.covers(date(10 + horizon + 1), calendar: calendar))
    }
}

@MainActor
final class QuickActionInboxTests: XCTestCase {
    override func tearDown() async throws {
        _ = QuickActionInbox.shared.take()
    }

    /// A cold-launch action is routed while auth is still bootstrapping, before
    /// `MainTabView` subscribes. It must still reach the tabs when they appear.
    func testActionRoutedBeforeTheTabsExistIsDeliveredWhenTheySubscribe() {
        AppQuickAction.newTrip.route()

        var received: [AppQuickAction] = []
        let subscription = QuickActionInbox.shared.actions.sink { received.append($0) }
        defer { subscription.cancel() }

        XCTAssertEqual(received, [.newTrip])
        XCTAssertNil(QuickActionInbox.shared.pending, "an action runs once")

        // While the tabs are on screen, an action is delivered straight away.
        AppQuickAction.today.route()
        XCTAssertEqual(received, [.newTrip, .today])
        XCTAssertNil(QuickActionInbox.shared.pending)

        // A later subscriber (tabs rebuilt after an account switch) does not
        // replay an action that already ran.
        var replayed: [AppQuickAction] = []
        let second = QuickActionInbox.shared.actions.sink { replayed.append($0) }
        second.cancel()
        XCTAssertTrue(replayed.isEmpty)
    }

    func testRouterReplaysAPersistedColdLaunchActionIntoTheInbox() {
        UserDefaults.standard.set(AppQuickAction.today.rawValue, forKey: AppQuickAction.pendingStorageKey)
        QuickActionRouter.activate()
        XCTAssertEqual(QuickActionInbox.shared.take(), .today)
        XCTAssertNil(UserDefaults.standard.string(forKey: AppQuickAction.pendingStorageKey))
    }
}
