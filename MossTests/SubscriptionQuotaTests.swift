import Foundation
import Supabase
import XCTest
@testable import Moss

final class SubscriptionQuotaTests: XCTestCase {
    func testCreationStatusDecodesAuthoritativeLifetimeUsage() throws {
        let status = try JSONDecoder().decode(
            TripCreationStatus.self,
            from: Data(
                """
                {
                  "lifetime_trip_count": 2,
                  "free_trip_allowance": 2,
                  "has_active_entitlement": false,
                  "can_create_trip": false
                }
                """.utf8
            )
        )

        XCTAssertEqual(status.lifetimeTripCount, 2)
        XCTAssertFalse(status.canCreateTrip)
    }

    func testQuotaErrorIsClassifiedSeparately() {
        let error = PostgrestError(
            detail: "MOSS_TRIP_LIMIT_REACHED",
            hint: "Subscribe",
            code: "P0001",
            message: "The lifetime free-trip allowance has been used."
        )

        XCTAssertEqual(TripsRepository.classifyCreationError(error), .quotaReached)
    }

    func testConnectivityErrorKeepsARecoverableMessage() {
        let result = TripsRepository.classifyCreationError(
            URLError(.notConnectedToInternet)
        )

        guard case .connectivity = result else {
            return XCTFail("Expected a connectivity-specific creation error")
        }
        XCTAssertTrue(result.errorDescription?.contains("draft is still here") == true)
    }

    func testFailedEntitlementMirrorIsRecoverableButNotPaidAccess() {
        let state = EntitlementVerificationState.verificationFailed(
            "Still confirming with Moss."
        )

        XCTAssertTrue(state.canRetry)
        XCTAssertNotEqual(state, .verified)
    }
}
