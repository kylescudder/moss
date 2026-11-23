import Foundation

@MainActor
enum AuthAppConfiguration {
    static let callbackScheme = "moss"
    static let keychainService = "app.getmoss.moss.auth"
    static let initialDisplayNamePath = "api/profile/name"
    static let bootstrapFailureState: AuthClient.State = .signedOut

    // Shared sign-in views
    static let signInLogo = SignInLogo(imageName: "AppLogoIcon", size: 78, cornerRadius: Theme.Radius.lg)
    static let signInTitle = "Moss"
    static let signInTagline = "Plan trips, keep every booking together, and know what's next today."
    /// Leaving the reset-password sheet signs out and retains local data.
    static let passwordRecoveryExit = PasswordRecoveryExit.signOut

    /// Moss keeps no other per-account state to reset after the user discards
    /// local data from the sign-in screen.
    static func didDiscardLocalAccount(_ services: AppServices) {}
}
