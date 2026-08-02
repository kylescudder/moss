import Foundation
import Supabase
import XCTest
@testable import Moss

@MainActor
final class SubscriptionQuotaTests: XCTestCase {
    func testLiveTripUniqueViolationIsIdempotentOnlyWhenServerRowExists() {
        let duplicate = PostgrestError(
            detail: "",
            hint: "",
            code: "23505",
            message: "duplicate"
        )

        XCTAssertTrue(SupabaseConnector.isIdempotentTripReplay(
            duplicate,
            serverRowExists: true
        ))
        XCTAssertFalse(SupabaseConnector.isIdempotentTripReplay(
            duplicate,
            serverRowExists: false
        ))
    }

    func testServerConfirmedBillingAllowsCreationWithStaleSnapshot() {
        XCTAssertTrue(TripCreationAuthorization.allowsUnlimitedCreation(
            billingIsSubscribed: true,
            snapshotIsVerified: false
        ))
    }

    func testUnconfirmedBillingCannotReplaceVerifiedSnapshot() {
        XCTAssertFalse(TripCreationAuthorization.allowsUnlimitedCreation(
            billingIsSubscribed: false,
            snapshotIsVerified: false
        ))
        XCTAssertTrue(TripCreationAuthorization.allowsUnlimitedCreation(
            billingIsSubscribed: false,
            snapshotIsVerified: true
        ))
    }

    func testPasswordRecoverySignOutWipesOnlyAfterSuccess() async {
        var wipes = 0
        let failed = await PasswordRecoveryCleanup.signOut(
            signOut: { false },
            wipe: { wipes += 1 }
        )
        XCTAssertFalse(failed)
        XCTAssertEqual(wipes, 0)

        let succeeded = await PasswordRecoveryCleanup.signOut(
            signOut: { true },
            wipe: { wipes += 1 }
        )
        XCTAssertTrue(succeeded)
        XCTAssertEqual(wipes, 1)
    }

    func testPasswordRecoveryUpdateWipesOnlyAfterSuccess() async {
        var wipes = 0
        let failed = await PasswordRecoveryCleanup.updatePassword(
            update: { false },
            wipe: { wipes += 1 }
        )
        XCTAssertFalse(failed)
        XCTAssertEqual(wipes, 0)

        let succeeded = await PasswordRecoveryCleanup.updatePassword(
            update: { true },
            wipe: { wipes += 1 }
        )
        XCTAssertTrue(succeeded)
        XCTAssertEqual(wipes, 1)
    }

    func testSyncIssuesPublishForRootPresentation() {
        let store = SyncIssueStore()
        store.rejectedChange(table: "itinerary_items")
        XCTAssertEqual(store.current?.title, "Offline change not synced")
    }

    func testMissingQuotaSnapshotIsBlocked() {
        XCTAssertThrowsError(try TripQuotaSnapshot.requireInitializedCount(nil)) { error in
            XCTAssertEqual(error as? TripCreationError, .quotaSnapshotUnavailable)
        }
    }

    func testConfirmedZeroQuotaIsDistinctFromMissingSnapshot() throws {
        XCTAssertEqual(try TripQuotaSnapshot.requireInitializedCount(0), 0)
    }

    func testUploadPermanentErrorClassificationDoesNotAcknowledgeRLS() {
        let quota = PostgrestError(detail: "MOSS_TRIP_LIMIT_REACHED", hint: "", code: "MS001", message: "limit")
        let constraint = PostgrestError(detail: "", hint: "", code: "23514", message: "check")
        let rls = PostgrestError(detail: "", hint: "", code: "42501", message: "denied")
        XCTAssertTrue(SupabaseConnector.isPermanentRejection(quota))
        XCTAssertTrue(SupabaseConnector.isPermanentRejection(constraint))
        XCTAssertFalse(SupabaseConnector.isPermanentRejection(rls))
    }
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
