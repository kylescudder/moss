import Combine
import Foundation
import PowerSync

@MainActor
final class TripsRepository: ObservableObject {
    @Published private(set) var trips: [Trip] = []
    @Published private(set) var isLoading = false

    private let auth: AuthClient
    private let billing: BillingRepository
    private let database: PowerSyncDatabaseProtocol
    private var tripWatchTask: Task<Void, Never>?
    private var quotaWatchTask: Task<Void, Never>?
    private var userID: String?

    init(auth: AuthClient, billing: BillingRepository, database: PowerSyncDatabaseProtocol) {
        self.auth = auth
        self.billing = billing
        self.database = database
    }

    deinit {
        tripWatchTask?.cancel()
        quotaWatchTask?.cancel()
    }

    /// Trips under way today, then upcoming trips, then past trips.
    var currentTrips: [Trip] { trips.filter { $0.isActive() } }
    var upcomingTrips: [Trip] {
        let today = Calendar.current.startOfDay(for: Date())
        return trips.filter { !$0.isActive() && ($0.startsAt ?? .distantFuture) >= today }
    }
    var pastTrips: [Trip] {
        let today = Calendar.current.startOfDay(for: Date())
        return trips
            .filter { !$0.isActive() && ($0.startsAt ?? .distantFuture) < today }
            .reversed()
    }

    func startWatching(userID: String) {
        guard self.userID != userID || tripWatchTask == nil else { return }
        self.userID = userID
        tripWatchTask?.cancel()
        quotaWatchTask?.cancel()
        isLoading = true

        let database = database
        tripWatchTask = Task { [weak self] in
            do {
                let stream = try database.watch(
                    sql: Self.selectSQL,
                    parameters: [userID],
                    mapper: Trip.from(cursor:)
                )
                for try await rows in stream {
                    guard !Task.isCancelled else { return }
                    self?.trips = rows.compactMap { $0 }
                    self?.isLoading = false
                }
            } catch {
                self?.isLoading = false
                Log.error(error, category: "trips.watch")
            }
        }

        quotaWatchTask = Task { [weak self] in
            do {
                let stream = try database.watch(
                    sql: "select lifetime_count from trip_creation_quotas where id = ?",
                    parameters: [userID],
                    mapper: { try $0.getInt(name: "lifetime_count") }
                )
                for try await rows in stream {
                    guard !Task.isCancelled, let count = rows.first else { continue }
                    await self?.reconcileAcceptedPendingTrips(serverLifetimeCount: count)
                }
            } catch {
                Log.error(error, category: "trips.quotaWatch")
            }
        }
    }

    func stopWatching() {
        tripWatchTask?.cancel()
        quotaWatchTask?.cancel()
        tripWatchTask = nil
        quotaWatchTask = nil
        userID = nil
        trips = []
        isLoading = false
    }

    func refresh() async {
        guard let userID else { return }
        do {
            let rows = try await database.getAll(
                sql: Self.selectSQL,
                parameters: [userID],
                mapper: Trip.from(cursor:)
            )
            trips = rows.compactMap { $0 }
            isLoading = false
        } catch {
            Log.error(error, category: "trips.refresh")
        }
    }

    @discardableResult
    func create(_ draft: TripDraft) async throws -> UUID {
        guard let userID else { throw TripCreationError.unauthenticated }

        let tripID = UUID()
        let id = tripID.uuidString.lowercased()
        let now = Date().iso8601
        let cachedStatus = try await localTripCreationStatus()
        let allowsUnlimited = billing.subscriptionState == .active
            || cachedStatus.hasVerifiedEntitlement
        let freeLimit = AppServices.freeTripLimit
        do {
            try await database.writeTransaction { transaction in
                let serverCount = try TripQuotaSnapshot.requireInitializedCount(
                    transaction.getOptional(
                        sql: "select lifetime_count from trip_creation_quotas where id = ?",
                        parameters: [userID],
                        mapper: { try $0.getInt(name: "lifetime_count") }
                    )
                )
                let pendingCount = try transaction.getOptional(
                    sql: """
                    select count(*) as count from pending_trips
                    where user_id = ? and expected_lifetime_count > ?
                    """,
                    parameters: [userID, serverCount],
                    mapper: { try $0.getInt(name: "count") }
                ) ?? 0
                let expectedLifetimeCount = serverCount + pendingCount + 1
                guard allowsUnlimited || expectedLifetimeCount <= freeLimit else {
                    throw TripCreationError.freeLimitReached
                }

                try transaction.execute(
                    sql: """
                    insert into pending_trips
                      (id, user_id, expected_lifetime_count, state, created_at)
                    values (?, ?, ?, 'queued', ?)
                    """,
                    parameters: [id, userID, expectedLifetimeCount, now]
                )
                try transaction.execute(
                    sql: """
                    insert into trips
                      (id, owner_id, title, destination, starts_at, ends_at, notes, created_at, updated_at)
                    values (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    parameters: [
                        id,
                        userID,
                        draft.title.nilIfBlank,
                        draft.destination.nilIfBlank,
                        draft.startsAt.iso8601,
                        draft.endsAt.iso8601,
                        draft.notes.nilIfBlank,
                        now,
                        now,
                    ]
                )
            }
            return tripID
        } catch {
            Log.error(error, category: "trips.create")
            throw TripCreationError.classify(error, subscriptionState: billing.subscriptionState)
        }
    }

    func update(_ trip: Trip, with draft: TripDraft) async {
        do {
            try await database.execute(
                sql: """
                update trips set
                  title = ?, destination = ?, starts_at = ?, ends_at = ?, notes = ?, updated_at = ?
                where id = ?
                """,
                parameters: [
                    draft.title.nilIfBlank,
                    draft.destination.nilIfBlank,
                    draft.startsAt.iso8601,
                    draft.endsAt.iso8601,
                    draft.notes.nilIfBlank,
                    Date().iso8601,
                    trip.id.uuidString.lowercased(),
                ]
            )
        } catch {
            Log.error(error, category: "trips.update")
        }
    }

    func softDelete(_ trip: Trip) async {
        do {
            let now = Date().iso8601
            try await database.execute(
                sql: "update trips set deleted_at = ?, updated_at = ? where id = ?",
                parameters: [now, now, trip.id.uuidString.lowercased()]
            )
        } catch {
            Log.error(error, category: "trips.delete")
        }
    }

    /// Prefer the transactional server status while online. AppServices falls
    /// back to `localTripCreationStatus` for offline operation.
    func tripCreationStatus() async throws -> TripCreationStatus {
        guard auth.currentUserID != nil else { throw TripCreationError.unauthenticated }
        do {
            let data = try await auth.api.request("api/trips/status")
            let status = try JSONDecoder().decode(TripCreationStatus.self, from: data)
            return try await statusIncludingLocalPending(status)
        } catch {
            Log.error(error, category: "trips.creationStatus")
            throw TripCreationError.classify(error, subscriptionState: billing.subscriptionState)
        }
    }

    func localTripCreationStatus() async throws -> TripCreationStatus {
        guard let userID else { throw TripCreationError.unauthenticated }
        let cachedServerCount = try await database.getOptional(
            sql: "select lifetime_count from trip_creation_quotas where id = ?",
            parameters: [userID],
            mapper: { try $0.getInt(name: "lifetime_count") }
        )
        let serverCount = try TripQuotaSnapshot.requireInitializedCount(cachedServerCount)
        let pendingCount = try await pendingTripCount(userID: userID, above: serverCount)
        let entitlementRows = try await database.getAll(
            sql: """
            select product_id, bundle_id, status, expires_at, revoked_at,
                   environment, signed_at, verified_at, verification_source
            from iap_entitlements where id = ?
            """,
            parameters: [userID],
            mapper: OfflineEntitlementSnapshot.from(cursor:)
        )
        let entitlement = entitlementRows.compactMap { $0 }.first
        return TripCreationStatus(
            lifetimeCount: serverCount + pendingCount,
            freeLimit: AppServices.freeTripLimit,
            hasVerifiedEntitlement: entitlement?.isCurrentlyVerified == true
        )
    }

    func createdTripCount() async throws -> Int {
        (try await localTripCreationStatus()).lifetimeCount
    }

    private func reconcileAcceptedPendingTrips(serverLifetimeCount: Int) async {
        do {
            try await database.execute(
                sql: """
                delete from pending_trips
                where state = 'accepted' and expected_lifetime_count <= ?
                """,
                parameters: [serverLifetimeCount]
            )
        } catch {
            Log.error(error, category: "trips.pendingReconcile")
        }
    }

    private func statusIncludingLocalPending(_ status: TripCreationStatus) async throws -> TripCreationStatus {
        guard let userID else { throw TripCreationError.unauthenticated }
        let pendingCount = try await pendingTripCount(userID: userID, above: status.lifetimeCount)
        return TripCreationStatus(
            lifetimeCount: status.lifetimeCount + pendingCount,
            freeLimit: status.freeLimit,
            hasVerifiedEntitlement: status.hasVerifiedEntitlement
        )
    }

    private func pendingTripCount(userID: String, above serverCount: Int) async throws -> Int {
        try await database.getOptional(
            sql: """
            select count(*) as count from pending_trips
            where user_id = ? and expected_lifetime_count > ?
            """,
            parameters: [userID, serverCount],
            mapper: { try $0.getInt(name: "count") }
        ) ?? 0
    }

    private static let selectSQL = """
        select * from trips
        where owner_id = ? and deleted_at is null
        order by starts_at asc, created_at asc
        """
}

struct OfflineEntitlementSnapshot: Sendable {
    let productID: String
    let bundleID: String?
    let status: String
    let expiresAt: Date?
    let revokedAt: Date?
    let environment: String?
    let signedAt: Date?
    let verifiedAt: Date?
    let verificationSource: String?

    var isCurrentlyVerified: Bool {
        isVerified(at: Date())
    }

    func isVerified(at date: Date) -> Bool {
        productID == BillingRepository.productID
            && bundleID == "app.getmoss.moss"
            && status == "active"
            && revokedAt == nil
            && signedAt != nil
            && verifiedAt != nil
            && ["Production", "Sandbox"].contains(environment ?? "")
            && ["device", "notification"].contains(verificationSource ?? "")
            && (expiresAt.map { $0 > date } == true)
    }

    static func from(cursor: SqlCursor) -> OfflineEntitlementSnapshot? {
        do {
            return OfflineEntitlementSnapshot(
                productID: try cursor.getString(name: "product_id"),
                bundleID: try cursor.getStringOptional(name: "bundle_id"),
                status: try cursor.getString(name: "status"),
                expiresAt: parseISO8601Date(try cursor.getStringOptional(name: "expires_at")),
                revokedAt: parseISO8601Date(try cursor.getStringOptional(name: "revoked_at")),
                environment: try cursor.getStringOptional(name: "environment"),
                signedAt: parseISO8601Date(try cursor.getStringOptional(name: "signed_at")),
                verifiedAt: parseISO8601Date(try cursor.getStringOptional(name: "verified_at")),
                verificationSource: try cursor.getStringOptional(name: "verification_source")
            )
        } catch {
            return nil
        }
    }
}

extension TripsRepository: CreationQuotaProviding {
    func lifetimeCreationCount() async throws -> Int {
        try await createdTripCount()
    }
}
