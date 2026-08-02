import Foundation
import PowerSync

@MainActor final class ProfileRepository: ObservableObject {
    @Published private(set) var profile: Profile?
    @Published private(set) var isLoading = false
    @Published var lastError: String?
    private let database: PowerSyncDatabaseProtocol
    private var task: Task<Void, Never>?
    private var userID: String?
    init(database: PowerSyncDatabaseProtocol) { self.database = database }
    deinit { task?.cancel() }
    func startWatching(userID: String) {
        guard self.userID != userID || task == nil else { return }; self.userID = userID; task?.cancel(); isLoading = true
        let database = database
        task = Task { [weak self] in do {
            for try await rows in try database.watch(sql: "select * from profiles where id = ? and deleted_at is null limit 1", parameters: [userID], mapper: Profile.from(cursor:)) {
                self?.profile = rows.compactMap { $0 }.first; self?.isLoading = false
            }
        } catch { self?.lastError = error.localizedDescription; self?.isLoading = false } }
    }
    func stopWatching() { task?.cancel(); task = nil; userID = nil; profile = nil; isLoading = false }
    func reset() { stopWatching(); lastError = nil }
    func refresh() async {}
    func updateDisplayName(_ name: String) async {
        guard let userID else { return }
        do { try await database.execute(sql: "update profiles set display_name = ?, updated_at = ? where id = ?", parameters: [name.trimmingCharacters(in: .whitespacesAndNewlines), Date().iso8601, userID]) }
        catch { lastError = error.localizedDescription }
    }
}
