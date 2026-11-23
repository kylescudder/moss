import XCTest
@testable import Moss

final class TripCreationErrorTests: XCTestCase {
    func testEveryCreationErrorHasTheExpectedPresentation() {
        XCTAssertEqual(TripCreationFailurePresentation.forError(.freeLimitReached), .paywall)
        XCTAssertEqual(
            TripCreationFailurePresentation.forError(.subscriptionVerificationPending),
            .verification(
                title: "Verifying subscription",
                message: "Apple has verified your subscription, but Moss is still confirming it with the server. Retry in a moment."
            )
        )
        for error in [
            TripCreationError.quotaSnapshotUnavailable,
            .unauthenticated,
            .networkFailure,
            .serverValidationFailure,
            .unknownFailure,
        ] {
            guard case .alert(let title, let message) = TripCreationFailurePresentation.forError(error) else {
                return XCTFail("\(error) should present an alert")
            }
            XCTAssertFalse(title.isEmpty)
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testLocalQuotaSnapshotDistinguishesUnknownFromConfirmedZero() throws {
        XCTAssertThrowsError(try TripQuotaSnapshot.requireInitializedCount(nil)) { error in
            XCTAssertEqual(error as? TripCreationError, .quotaSnapshotUnavailable)
        }
        XCTAssertEqual(try TripQuotaSnapshot.requireInitializedCount(0), 0)
    }

    func testServerLimitMapsToVerificationWhileMirrorIsPending() {
        let limit = APIError(code: "MX001", message: "Free trip limit reached.")
        XCTAssertEqual(TripCreationError.classify(limit, subscriptionState: .free), .freeLimitReached)
        XCTAssertEqual(
            TripCreationError.classify(limit, subscriptionState: .verifying),
            .subscriptionVerificationPending
        )
    }

    func testErrorClassificationDistinguishesRequiredFailures() {
        for code in ["MX002", "DX002"] {
            XCTAssertEqual(
                TripCreationError.classify(APIError(code: code, message: nil), subscriptionState: .free),
                .unauthenticated,
                code
            )
        }
        for code in ["MX003", "MX004", "MX005", "42501", "23514"] {
            XCTAssertEqual(
                TripCreationError.classify(APIError(code: code, message: nil), subscriptionState: .free),
                .serverValidationFailure,
                code
            )
        }
        XCTAssertEqual(
            TripCreationError.classify(
                APIError(code: "temporarily_unavailable", message: nil),
                subscriptionState: .free
            ),
            .networkFailure
        )
        XCTAssertEqual(
            TripCreationError.classify(URLError(.notConnectedToInternet), subscriptionState: .free),
            .networkFailure
        )
        XCTAssertEqual(
            TripCreationError.classify(NSError(domain: "test", code: 1), subscriptionState: .free),
            .unknownFailure
        )
    }

    func testQuotaAndSubscriptionStateResolveAvailability() {
        let limit = AppServices.freeTripLimit
        let remaining = TripCreationStatus(lifetimeCount: limit - 1, freeLimit: limit, hasVerifiedEntitlement: false)
        XCTAssertEqual(TripCreationAvailability.resolve(status: remaining, subscriptionState: .free), .allowed)

        let exhausted = TripCreationStatus(lifetimeCount: limit, freeLimit: limit, hasVerifiedEntitlement: false)
        XCTAssertEqual(TripCreationAvailability.resolve(status: exhausted, subscriptionState: .free), .limitReached)
        XCTAssertEqual(
            TripCreationAvailability.resolve(status: exhausted, subscriptionState: .verifying),
            .subscriptionVerificationPending
        )

        let subscriber = TripCreationStatus(lifetimeCount: 40, freeLimit: limit, hasVerifiedEntitlement: true)
        XCTAssertEqual(TripCreationAvailability.resolve(status: subscriber, subscriptionState: .active), .allowed)
    }

    func testServerStatusDecodesTheBackendContract() throws {
        let json = Data(#"{"lifetime_count":1,"free_limit":2,"has_verified_entitlement":false}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(TripCreationStatus.self, from: json),
            TripCreationStatus(lifetimeCount: 1, freeLimit: 2, hasVerifiedEntitlement: false)
        )
    }

    func testPowerSyncAcknowledgesOnlyKnownPermanentRejections() {
        XCTAssertTrue(APIConnector.isPermanentRejection(APIError(code: "MX001", message: nil)))
        XCTAssertTrue(APIConnector.isPermanentRejection(APIError(code: "MX003", message: nil)))
        XCTAssertTrue(APIConnector.isPermanentRejection(APIError(code: "23514", message: nil)))
        XCTAssertFalse(APIConnector.isPermanentRejection(APIError(code: "MX002", message: nil)))
        XCTAssertFalse(APIConnector.isPermanentRejection(APIError(code: "42501", message: nil)))
        XCTAssertFalse(APIConnector.isPermanentRejection(APIError(code: "temporarily_unavailable", message: nil)))
        XCTAssertFalse(APIConnector.isPermanentRejection(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        ))
    }
}
