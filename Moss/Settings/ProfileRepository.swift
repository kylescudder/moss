import Foundation
import Supabase

@MainActor
final class ProfileRepository: ObservableObject {
    @Published private(set) var profile: Profile?
    @Published private(set) var isLoading = false
    @Published var lastError: String?

    private let auth: AuthClient

    init(auth: AuthClient) {
        self.auth = auth
    }

    func reset() {
        profile = nil
        lastError = nil
    }

    func refresh() async {
        guard let userID = auth.currentUserID else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            profile = try await auth.supabase
                .from("profiles")
                .select()
                .eq("id", value: userID.uuidString)
                .single()
                .execute()
                .value
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "profile.refresh")
        }
    }

    func updateDisplayName(_ displayName: String) async {
        guard let userID = auth.currentUserID else { return }
        do {
            let payload = ["display_name": displayName.trimmingCharacters(in: .whitespacesAndNewlines)]
            profile = try await auth.supabase
                .from("profiles")
                .update(payload)
                .eq("id", value: userID.uuidString)
                .select()
                .single()
                .execute()
                .value
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "profile.update")
        }
    }
}

