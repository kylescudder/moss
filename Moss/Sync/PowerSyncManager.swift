import Combine
import Foundation
import PowerSync

@MainActor final class PowerSyncManager: ObservableObject {
    private static let requiresWipeKey = "sync.requiresWipeBeforeConnect"
    enum Status: Equatable { case idle, connecting, connected, offline, error(String) }
    @Published private(set) var status: Status = .idle
    @Published private(set) var pendingUploadCount = 0
    let database: PowerSyncDatabaseProtocol
    private let auth: AuthClient
    private let issues: SyncIssueStore
    private var connector: SupabaseConnector?
    private var cancellables = Set<AnyCancellable>()
    private var statusTask: Task<Void, Never>?
    private var countTask: Task<Void, Never>?

    init(auth: AuthClient, issues: SyncIssueStore) {
        self.auth = auth
        self.issues = issues
        database = PowerSyncDatabase(schema: DatabaseSchema.schema, dbFilename: "moss.sqlite")
    }
    deinit { statusTask?.cancel(); countTask?.cancel() }

    func startObservingAuth() async {
        auth.$state.removeDuplicates().sink { [weak self] state in
            Task { @MainActor [weak self] in await self?.reconcile(state) }
        }.store(in: &cancellables)
        let database = database
        statusTask = Task { [weak self] in
            for await update in database.currentStatus.asFlow() {
                guard !Task.isCancelled else { return }
                if let error = update.anyError { self?.status = .error(String(describing: error)) }
                else if update.connected { self?.status = .connected }
                else if update.connecting { self?.status = .connecting }
                else if update.hasSynced == true { self?.status = .offline }
                else { self?.status = .idle }
            }
        }
        countTask = Task { [weak self] in
            do {
                for try await rows in try database.watch(sql: "select count(*) as count from ps_crud", parameters: [], mapper: { try $0.getInt(name: "count") }) {
                    self?.pendingUploadCount = rows.first ?? 0
                }
            } catch { Log.error(error, category: "sync.pendingCount") }
        }
        await reconcile(auth.state)
    }

    private func reconcile(_ state: AuthClient.State) async {
        switch state {
        case .unknown: break
        case .signedOut: await disconnect()
        case .signedIn: await connect()
        }
    }
    private func connect() async {
        guard connector == nil else { return }
        if UserDefaults.standard.bool(forKey: Self.requiresWipeKey) {
            do { try await database.disconnectAndClear(); UserDefaults.standard.removeObject(forKey: Self.requiresWipeKey) }
            catch { status = .error("Offline data must be cleared before syncing another account."); issues.localClearFailed(); return }
        }
        if let error = AppSecrets.powerSyncConfigurationError { status = .error(error); return }
        status = .connecting
        let next = SupabaseConnector(auth: auth, issues: issues)
        connector = next
        do { try await database.connect(connector: next) }
        catch { connector = nil; status = .error(error.localizedDescription); Log.error(error, category: "sync.connect") }
    }
    private func disconnect() async {
        guard connector != nil else { return }
        do { try await database.disconnect(); connector = nil; status = .idle }
        catch { Log.error(error, category: "sync.disconnect") }
    }
    func wipe() async {
        UserDefaults.standard.set(true, forKey: Self.requiresWipeKey)
        do {
            try await database.disconnectAndClear()
            UserDefaults.standard.removeObject(forKey: Self.requiresWipeKey)
            connector = nil; pendingUploadCount = 0; status = .idle
        } catch { issues.localClearFailed(); Log.error(error, category: "sync.wipe") }
    }
}
