import Foundation
import PowerSync
import Supabase

final class SupabaseConnector: PowerSyncBackendConnectorProtocol, @unchecked Sendable {
    private static let writableTables = Set(["profiles", "trips", "itinerary_items"])
    private let auth: AuthClient
    private let issues: SyncIssueStore
    init(auth: AuthClient, issues: SyncIssueStore) { self.auth = auth; self.issues = issues }

    func fetchCredentials() async throws -> PowerSyncCredentials? {
        guard let endpoint = AppSecrets.powerSyncURL?.absoluteString,
              let token = await auth.currentAccessToken() else { return nil }
        return PowerSyncCredentials(endpoint: endpoint, token: token)
    }
    func uploadData(database: PowerSyncDatabaseProtocol) async throws {
        guard let batch = try await database.getCrudBatch() else { return }
        for entry in batch.crud {
            guard Self.writableTables.contains(entry.table) else { throw SyncUploadError.unexpectedTable(entry.table) }
            do {
                try await upload(entry)
                if entry.table == "trips", entry.op == .put {
                    try? await database.execute(sql: "update pending_trips set state = 'accepted' where id = ?", parameters: [entry.id])
                }
            } catch {
                guard Self.isPermanentRejection(error) else { throw error }
                Log.error(error, category: "sync.upload.rejected")
                if entry.table == "trips" {
                    try? await database.execute(sql: "delete from pending_trips where id = ?", parameters: [entry.id])
                    await issues.rejectedTrip(TripsRepository.classifyCreationError(error))
                } else { await issues.rejectedChange(table: entry.table) }
            }
        }
        try await batch.complete()
    }
    private func upload(_ entry: CrudEntry) async throws {
        let table = auth.supabase.from(entry.table)
        switch entry.op {
        case .put:
            var payload = entry.opData ?? [:]; sanitize(&payload, table: entry.table, isInsert: true); payload["id"] = entry.id
            if entry.table == "trips" {
                do { try await table.insert(payload).execute() }
                catch {
                    let serverRowExists = Self.isUnique(error)
                        ? try await serverTripExists(entry.id)
                        : false
                    if Self.isIdempotentTripReplay(
                        error,
                        serverRowExists: serverRowExists
                    ) { return }
                    throw error
                }
            } else { try await table.upsert(payload).execute() }
        case .patch:
            guard var payload = entry.opData else { return }; sanitize(&payload, table: entry.table, isInsert: false)
            guard !payload.isEmpty else { return }
            try await table.update(payload).eq("id", value: entry.id).execute()
        case .delete:
            try await table.delete().eq("id", value: entry.id).execute()
        }
    }
    private func serverTripExists(_ id: String) async throws -> Bool {
        struct Existing: Decodable { let id: String }
        let rows: [Existing] = try await auth.supabase.from("trips").select("id").eq("id", value: id).limit(1).execute().value
        return !rows.isEmpty
    }
    private func sanitize<V>(_ payload: inout [String: V], table: String, isInsert: Bool) {
        payload.removeValue(forKey: "created_at")
        if !isInsert {
            payload.removeValue(forKey: "owner_id")
            if table == "itinerary_items" { payload.removeValue(forKey: "trip_id") }
        }
    }
    static func isPermanentRejection(_ error: Error) -> Bool {
        guard let error = error as? PostgrestError else { return false }
        return ["MS001", "MS002"].contains(error.code) || ["23502", "23503", "23505", "23514"].contains(error.code)
    }
    static func isIdempotentTripReplay(
        _ error: Error,
        serverRowExists: Bool
    ) -> Bool {
        isUnique(error) && serverRowExists
    }
    private static func isUnique(_ error: Error) -> Bool { (error as? PostgrestError)?.code == "23505" }
}
private enum SyncUploadError: LocalizedError {
    case unexpectedTable(String)
    var errorDescription: String? { if case .unexpectedTable(let table) = self { return "Unexpected PowerSync writable table: \(table)" }; return nil }
}
