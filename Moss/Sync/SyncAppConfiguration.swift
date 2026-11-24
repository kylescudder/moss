import Foundation
import PowerSync

/// Moss's values for the shared sync core (`PowerSyncManager`, `APIConnector`,
/// `SyncIssueStore`). The local schema lives in `DatabaseSchema.swift`.
enum SyncAppConfiguration {
    static let databaseFilename = "moss.sqlite"

    /// Every account that owns local rows or pending creations. Trips shared
    /// with this account belong to someone else, so a trip (and its items)
    /// only counts while it is not shared with anyone: a shared trip's owner
    /// is already known from `profiles`.
    static let offlineOwnerQuery = """
        select id from profiles
        union select user_id as id from pending_trips
        union select owner_id as id from trips
          where id not in (select trip_id from trip_members where role <> 'owner')
            and owner_id not in (select library_id from library_members where role <> 'owner')
        union select owner_id as id from itinerary_items
          where trip_id not in (select trip_id from trip_members where role <> 'owner')
            and owner_id not in (select library_id from library_members where role <> 'owner')
        """

    /// Tables PowerSync may upload. Read-only snapshots (quota, entitlement)
    /// must never enter the CRUD queue.
    static let writableTables = Set(["profiles", "trips", "itinerary_items"])

    /// `MX001` lifetime limit, `MX003` invalid trip or item, and Postgres
    /// not-null, foreign-key, unique and check violations.
    static let permanentRejectionCodes: Set<String> = ["MX001", "MX003", "23502", "23503", "23505", "23514"]

    static let localClearFailureMessage =
        "Moss signed out but could not clear its offline database. It will retry before another account can sync on this device."

    /// An accepted trip insert confirms its pending creation reservation.
    @MainActor
    static func didUpload(_ entry: CrudEntry, database: PowerSyncDatabaseProtocol) async throws {
        guard entry.table == "trips", entry.op == .put else { return }
        _ = try? await database.execute(
            sql: "update pending_trips set state = 'accepted' where id = ?",
            parameters: [entry.id]
        )
    }

    /// A rejected trip releases its reservation; PowerSync restores the row.
    @MainActor
    static func didReject(
        _ entry: CrudEntry,
        error: Error,
        database: PowerSyncDatabaseProtocol,
        issues: SyncIssueStore
    ) async throws {
        if entry.table == "trips", entry.op == .put {
            _ = try? await database.execute(
                sql: "delete from pending_trips where id = ?",
                parameters: [entry.id]
            )
            issues.reportRejectedTrip(TripCreationError.classify(error, subscriptionState: .free))
        } else {
            issues.reportRejectedChange(table: entry.table)
        }
    }
}
