import Foundation
import Security

/// Moss's values for the shared push adapters (`PushManager`,
/// `PushRegistration`, `AuthClient+PushIdentity`).
enum PushAppConfiguration {
    /// The Keychain item that holds Moss's gateway installation ID. Changing
    /// it would give every device a new installation.
    static let installationIDKeychainService: String? = Bundle.main.bundleIdentifier ?? "app.getmoss.moss"
    static let installationIDKeychainAccessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String

    // Shared `PushAuthorizationRow` copy in Settings.
    static let settingsAllowedText = "Push notifications allowed"
    static let settingsDeniedText = "Push notifications disabled in iOS Settings"
    static let settingsEnableTitle = "Turn on push notifications"
    static let settingsUnknownText = "Push notification status unknown"

    static let fallbackBundleID = "app.getmoss.moss"

    /// Moss has no server-originated push yet; a tap simply opens the app.
    static func route(for userInfo: [AnyHashable: Any]) -> PushRoute? {
        nil
    }
}
