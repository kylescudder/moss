import Combine
import Foundation
import PowerSync

@MainActor
final class ProfileRepository: ObservableObject {
    @Published private(set) var profile: Profile?
    @Published private(set) var isLoading = false

    private let database: PowerSyncDatabaseProtocol
    private var watchTask: Task<Void, Never>?
    private var userID: String?

    init(database: PowerSyncDatabaseProtocol) {
        self.database = database
    }

    deinit { watchTask?.cancel() }

    func startWatching(userID: String) {
        guard self.userID != userID || watchTask == nil else { return }
        self.userID = userID
        watchTask?.cancel()
        isLoading = true
        let database = database
        watchTask = Task { [weak self] in
            do {
                let stream = try database.watch(
                    sql: Self.selectSQL,
                    parameters: [userID],
                    mapper: Profile.from(cursor:)
                )
                for try await rows in stream {
                    guard !Task.isCancelled else { return }
                    self?.profile = rows.compactMap { $0 }.first
                    self?.isLoading = false
                }
            } catch {
                self?.isLoading = false
                Log.error(error, category: "profile.watch")
            }
        }
    }

    func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
        userID = nil
        profile = nil
        isLoading = false
    }

    func refresh() async {
        guard let userID else { return }
        do {
            let rows = try await database.getAll(
                sql: Self.selectSQL,
                parameters: [userID],
                mapper: Profile.from(cursor:)
            )
            profile = rows.compactMap { $0 }.first
        } catch {
            Log.error(error, category: "profile.refresh")
        }
    }

    func updateDisplayName(_ name: String) async {
        guard let userID else { return }
        do {
            try await database.execute(
                sql: "update profiles set display_name = ?, updated_at = ? where id = ?",
                parameters: [name, Date().iso8601, userID]
            )
        } catch {
            Log.error(error, category: "profile.updateDisplayName")
        }
    }

    private static let selectSQL = """
        select * from profiles
        where id = ? and deleted_at is null
        limit 1
        """
}
