import Foundation
import PowerSync
import Supabase

@MainActor final class TripsRepository: ObservableObject {
    @Published private(set) var trips: [Trip] = []
    @Published private(set) var isLoading = false
    @Published var lastError: String?
    private let auth: AuthClient
    private let database: PowerSyncDatabaseProtocol
    private var tripsTask: Task<Void, Never>?
    private var quotaTask: Task<Void, Never>?
    private var userID: String?
    init(auth: AuthClient, billing: BillingRepository, database: PowerSyncDatabaseProtocol) {
        self.auth = auth; _ = billing; self.database = database
    }
    deinit { tripsTask?.cancel(); quotaTask?.cancel() }
    func startWatching(userID: String) {
        guard self.userID != userID || tripsTask == nil else { return }; self.userID = userID
        tripsTask?.cancel(); quotaTask?.cancel(); isLoading = true; let database = database
        tripsTask = Task { [weak self] in do {
            for try await rows in try database.watch(sql: Self.selectSQL, parameters: [userID, userID], mapper: Trip.from(cursor:)) {
                self?.trips = rows.compactMap { $0 }; self?.isLoading = false
            }
        } catch { self?.lastError = error.localizedDescription; self?.isLoading = false } }
        quotaTask = Task { [weak self] in do {
            for try await rows in try database.watch(sql: "select lifetime_trip_count from trip_creation_quotas where id = ?", parameters: [userID], mapper: { try $0.getInt(name: "lifetime_trip_count") }) {
                if let count = rows.first { try? await self?.database.execute(sql: "delete from pending_trips where state = 'accepted' and expected_lifetime_count <= ?", parameters: [count]) }
            }
        } catch { Log.error(error, category: "trips.quotaWatch") } }
    }
    func stopWatching() { tripsTask?.cancel(); quotaTask?.cancel(); tripsTask = nil; quotaTask = nil; userID = nil; trips = []; isLoading = false }
    func reset() { stopWatching(); lastError = nil }
    func refresh() async {}

    func creationStatus() async throws -> TripCreationStatus {
        guard userID != nil else { throw TripCreationError.authenticationRequired }
        do {
            let rows: [TripCreationStatus] = try await auth.supabase.rpc("get_trip_creation_status").execute().value
            guard let status = rows.first else { throw TripCreationError.unknown("Empty trip allowance status.") }
            return try await includingPending(status)
        } catch { throw Self.classifyCreationError(error) }
    }
    func localCreationStatus() async throws -> TripCreationStatus {
        guard let userID else { throw TripCreationError.authenticationRequired }
        let snapshot = try await database.getOptional(sql: "select lifetime_trip_count from trip_creation_quotas where id = ?", parameters: [userID], mapper: { try $0.getInt(name: "lifetime_trip_count") })
        let serverCount = try TripQuotaSnapshot.requireInitializedCount(snapshot)
        let pending = try await pendingCount(userID: userID, above: serverCount)
        return TripCreationStatus(lifetimeTripCount: serverCount + pending, freeTripAllowance: AppServices.freeTripCreationLimit,
            hasActiveEntitlement: try await hasVerifiedOfflineEntitlement(userID: userID), subscriptionVerificationPending: false)
    }
    func lifetimeTripCount() async throws -> Int { try await localCreationStatus().lifetimeTripCount }
    func create(_ draft: TripDraft) async -> Result<Trip, TripCreationError> {
        guard let userID else { return .failure(.authenticationRequired) }
        let id = UUID().uuidString.lowercased(), now = Date().iso8601
        do {
            let cached = try await localCreationStatus()
            // Only the replicated server-verified snapshot can authorize an
            // unlimited write. Local StoreKit state is display/retry context.
            let unlimited = cached.hasActiveEntitlement
            try await database.writeTransaction { transaction in
                let value = try transaction.getOptional(sql: "select lifetime_trip_count from trip_creation_quotas where id = ?", parameters: [userID], mapper: { try $0.getInt(name: "lifetime_trip_count") })
                let serverCount = try TripQuotaSnapshot.requireInitializedCount(value)
                let pending = try transaction.getOptional(sql: "select count(*) as count from pending_trips where user_id = ? and expected_lifetime_count > ?", parameters: [userID, serverCount], mapper: { try $0.getInt(name: "count") }) ?? 0
                let expected = serverCount + pending + 1
                guard unlimited || expected <= AppServices.freeTripCreationLimit else { throw TripCreationError.quotaReached }
                try transaction.execute(sql: "insert into pending_trips (id,user_id,expected_lifetime_count,state,created_at) values (?,?,?,'queued',?)", parameters: [id,userID,expected,now])
                try transaction.execute(sql: "insert into trips (id,owner_id,title,destination,starts_at,ends_at,notes,created_at,updated_at) values (?,?,?,?,?,?,?,?,?)", parameters: [id,userID,draft.title.trimmingCharacters(in: .whitespacesAndNewlines),draft.destination.trimmingCharacters(in: .whitespacesAndNewlines),draft.startsAt.iso8601,draft.endsAt.iso8601,draft.notes.nilIfBlank,now,now])
            }
            let trip = Trip(id: UUID(uuidString: id)!, ownerID: UUID(uuidString: userID)!, title: draft.title, destination: draft.destination, startsAt: draft.startsAt, endsAt: draft.endsAt, notes: draft.notes.nilIfBlank, createdAt: Date(), updatedAt: Date(), deletedAt: nil)
            return .success(trip)
        } catch { let classified = Self.classifyCreationError(error); lastError = classified.errorDescription; return .failure(classified) }
    }
    func update(_ trip: Trip) async { do { try await database.execute(sql: "update trips set title=?,destination=?,starts_at=?,ends_at=?,notes=?,updated_at=? where id=?", parameters: [trip.title,trip.destination,trip.startsAt?.iso8601,trip.endsAt?.iso8601,trip.notes,Date().iso8601,trip.id.uuidString.lowercased()]) } catch { lastError = error.localizedDescription } }
    func softDelete(_ trip: Trip) async { do { let now=Date().iso8601; try await database.execute(sql: "update trips set deleted_at=?,updated_at=? where id=?", parameters: [now,now,trip.id.uuidString.lowercased()]) } catch { lastError=error.localizedDescription } }

    private func includingPending(_ status: TripCreationStatus) async throws -> TripCreationStatus { guard let userID else { throw TripCreationError.authenticationRequired }; return TripCreationStatus(lifetimeTripCount: status.lifetimeTripCount + (try await pendingCount(userID: userID, above: status.lifetimeTripCount)), freeTripAllowance: status.freeTripAllowance, hasActiveEntitlement: status.hasActiveEntitlement, subscriptionVerificationPending: status.subscriptionVerificationPending) }
    private func pendingCount(userID: String, above count: Int) async throws -> Int { try await database.getOptional(sql: "select count(*) as count from pending_trips where user_id=? and expected_lifetime_count>?", parameters: [userID,count], mapper: { try $0.getInt(name:"count") }) ?? 0 }
    private func hasVerifiedOfflineEntitlement(userID: String) async throws -> Bool {
        struct Snapshot { let product,bundle,status:String; let expires,revoked,signed,verified:Date?; let environment,source:String? }
        let rows = try await database.getAll(sql: "select product_id,bundle_id,status,expires_at,revoked_at,environment,signed_at,verified_at,verification_source from iap_entitlements where user_id=?", parameters:[userID]) { c in Snapshot(product:try c.getString(name:"product_id"),bundle:try c.getString(name:"bundle_id"),status:try c.getString(name:"status"),expires:parseISO8601Date(try c.getStringOptional(name:"expires_at")),revoked:parseISO8601Date(try c.getStringOptional(name:"revoked_at")),signed:parseISO8601Date(try c.getStringOptional(name:"signed_at")),verified:parseISO8601Date(try c.getStringOptional(name:"verified_at")),environment:try c.getStringOptional(name:"environment"),source:try c.getStringOptional(name:"verification_source")) }
        return rows.contains { $0.product == "app.moss.supporter.monthly" && $0.bundle == "app.getmoss.moss" && $0.status == "active" && $0.revoked == nil && $0.expires.map{$0>Date()} == true && $0.signed != nil && $0.verified != nil && ["Production","Sandbox"].contains($0.environment ?? "") && ["app_store_transaction_jws","app_store_server_notification_v2"].contains($0.source ?? "") }
    }
    static func classifyCreationError(_ error: Error) -> TripCreationError { if let e=error as? TripCreationError{return e}; if let e=error as? PostgrestError { if e.code=="MS001" {return .quotaReached}; if e.code=="MS002" {return .subscriptionVerificationPending}; if ["28000","PGRST301","PGRST302","PGRST303"].contains(e.code){return .authenticationRequired}; if e.code=="42501" || e.code.hasPrefix("22") || e.code.hasPrefix("23"){return .serverValidation(e.message)}; return .unknown(e.message) }; if error is URLError{return .connectivity(error.localizedDescription)}; return .unknown(error.localizedDescription) }
    private static let selectSQL = "select distinct trips.* from trips left join trip_members on trip_members.trip_id=trips.id where (trips.owner_id=? or trip_members.user_id=?) and trips.deleted_at is null order by trips.starts_at asc"
}

enum TripQuotaSnapshot { static func requireInitializedCount(_ count:Int?) throws -> Int { guard let count else { throw TripCreationError.quotaSnapshotUnavailable }; return count } }
struct TripCreationStatus: Decodable, Equatable { let lifetimeTripCount:Int; let freeTripAllowance:Int; let hasActiveEntitlement:Bool; let subscriptionVerificationPending:Bool; var canCreateTrip:Bool { hasActiveEntitlement || lifetimeTripCount < freeTripAllowance }; enum CodingKeys:String,CodingKey { case lifetimeTripCount="lifetime_trip_count",freeTripAllowance="free_trip_allowance",hasActiveEntitlement="has_active_entitlement",subscriptionVerificationPending="subscription_verification_pending" }; init(lifetimeTripCount:Int,freeTripAllowance:Int,hasActiveEntitlement:Bool,subscriptionVerificationPending:Bool){self.lifetimeTripCount=lifetimeTripCount;self.freeTripAllowance=freeTripAllowance;self.hasActiveEntitlement=hasActiveEntitlement;self.subscriptionVerificationPending=subscriptionVerificationPending}; init(from decoder:Decoder)throws{let c=try decoder.container(keyedBy:CodingKeys.self);lifetimeTripCount=try c.decode(Int.self,forKey:.lifetimeTripCount);freeTripAllowance=try c.decode(Int.self,forKey:.freeTripAllowance);hasActiveEntitlement=try c.decode(Bool.self,forKey:.hasActiveEntitlement);subscriptionVerificationPending=try c.decodeIfPresent(Bool.self,forKey:.subscriptionVerificationPending) ?? false} }
enum TripCreationError: LocalizedError,Equatable { case quotaReached,quotaSnapshotUnavailable,subscriptionVerificationPending,authenticationRequired,connectivity(String),serverValidation(String),unknown(String); var errorDescription:String? { switch self { case .quotaReached:return "You've used both free lifetime trip creations. Deleting a trip doesn't restore one."; case .quotaSnapshotUnavailable:return "Finish the initial sync before saving a trip offline."; case .subscriptionVerificationPending:return "Your subscription still needs server confirmation."; case .authenticationRequired:return "Moss couldn't verify your signed-in session."; case .connectivity:return "Moss couldn't connect. Your draft is still here."; case .serverValidation(let m),.unknown(let m):return "Moss couldn't save this trip. Your draft is still here. \(m)" } } }
