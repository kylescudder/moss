import Foundation
import PowerSync
import XCTest
@testable import AppUnderTest

@MainActor
final class PremiumCreationTests: XCTestCase {
    func testCachedPremiumProfileAllowsCreationAndRevocationRestoresTheCap() async throws {
        let database = PowerSyncDatabase(schema: DatabaseSchema.schema, dbFilename: "premium-\(UUID().uuidString).sqlite")
        let owner = UUID().uuidString.lowercased()
        let auth = AuthClient()
        let billing = BillingRepository(auth: auth)
        let repository = TripsRepository(auth: auth, billing: billing, database: database)
        repository.startWatching(userID: owner)
        try await database.execute(sql: "insert into profiles (id, is_premium_account) values (?, 1)", parameters: [owner])
        try await database.execute(sql: "insert into trip_creation_quotas (id, lifetime_count) values (?, 2)", parameters: [owner])
        // No StoreKit grant or billing override: the repository must read the
        // durable account profile before the profile watch has populated billing.
        XCTAssertFalse(billing.isSubscribed)
        let premium = try await repository.localTripCreationStatus()
        XCTAssertTrue(premium.hasVerifiedEntitlement)
        XCTAssertEqual(TripCreationAvailability.resolve(status: premium, subscriptionState: .free), .allowed)
        _ = try await repository.create(TripDraft())
        let afterCreate = try await repository.localTripCreationStatus()
        XCTAssertEqual(afterCreate.lifetimeCount, 3)
        try await database.execute(sql: "update profiles set is_premium_account = 0 where id = ?", parameters: [owner])
        let revoked = try await repository.localTripCreationStatus()
        XCTAssertFalse(revoked.hasVerifiedEntitlement)
        XCTAssertEqual(TripCreationAvailability.resolve(status: revoked, subscriptionState: .free), .limitReached)
        do {
            _ = try await repository.create(TripDraft())
            XCTFail("Revoked premium access must respect the exhausted allowance")
        } catch {
            XCTAssertEqual(error as? TripCreationError, .freeLimitReached)
        }
        repository.stopWatching()
        try await database.close(deleteDatabase: true)
    }
}
