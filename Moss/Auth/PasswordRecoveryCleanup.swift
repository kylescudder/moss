import Foundation

enum PasswordRecoveryCleanup {
    @MainActor
    static func signOut(
        signOut: () async -> Bool,
        wipe: () async -> Void
    ) async -> Bool {
        guard await signOut() else { return false }
        await wipe()
        return true
    }

    @MainActor
    static func updatePassword(
        update: () async -> Bool,
        wipe: () async -> Void
    ) async -> Bool {
        guard await update() else { return false }
        await wipe()
        return true
    }
}
