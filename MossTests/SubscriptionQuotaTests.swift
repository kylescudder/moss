import Foundation
import Supabase
import XCTest
@testable import Moss

@MainActor
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
                  "subscription_verification_pending": true,
                  "can_create_trip": false
                }
                """.utf8
            )
        )

        XCTAssertEqual(status.lifetimeTripCount, 2)
        XCTAssertTrue(status.subscriptionVerificationPending)
        XCTAssertFalse(status.canCreateTrip)
    }

    func testQuotaErrorIsClassifiedSeparately() {
        let error = PostgrestError(
            detail: "MOSS_TRIP_LIMIT_REACHED",
            hint: "Subscribe",
            code: "MS001",
            message: "A deliberately unrelated human-readable message."
        )

        XCTAssertEqual(TripsRepository.classifyCreationError(error), .quotaReached)
    }

    func testVerificationPendingUsesStructuredIdentifier() {
        let error = PostgrestError(
            detail: "MOSS_SUBSCRIPTION_VERIFICATION_PENDING",
            hint: "Retry verification",
            code: "MS002",
            message: "A deliberately unrelated human-readable message."
        )

        XCTAssertEqual(
            TripsRepository.classifyCreationError(error),
            .subscriptionVerificationPending
        )
    }

    func testAuthenticationUsesStructuredPostgRESTCode() {
        let error = PostgrestError(
            detail: "",
            hint: "",
            code: "PGRST301",
            message: "JWT expired"
        )

        XCTAssertEqual(
            TripsRepository.classifyCreationError(error),
            .authenticationRequired
        )
    }

    func testServerValidationIsSeparateFromUnknownFailure() {
        let validation = PostgrestError(
            detail: "MOSS_TRIP_OWNER_MISMATCH",
            hint: "",
            code: "42501",
            message: "Owner mismatch"
        )
        XCTAssertEqual(
            TripsRepository.classifyCreationError(validation),
            .serverValidation("Owner mismatch")
        )

        let unknown = NSError(domain: "MossTests", code: 1)
        guard case .unknown = TripsRepository.classifyCreationError(unknown) else {
            return XCTFail("Expected an unknown creation error")
        }
    }

    func testLegacyGenericSqlStateDoesNotMasqueradeAsQuota() {
        let error = PostgrestError(
            detail: "MOSS_TRIP_LIMIT_REACHED",
            hint: "",
            code: "P0001",
            message: "The old quota error"
        )

        XCTAssertEqual(
            TripsRepository.classifyCreationError(error),
            .unknown("The old quota error")
        )
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
