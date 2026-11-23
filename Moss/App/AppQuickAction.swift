import Foundation

/// Moss's quick actions for the shared `QuickActionRouter`. Keep widgets,
/// App Intents, URL path names, raw values and notification names in sync.
enum AppQuickAction: String, CaseIterable {
    case newTrip
    case today

    /// Where an action waits until the UI is ready. Keep the key stable.
    static let pendingStorageKey = "moss.pendingQuickAction"

    @MainActor
    func route() {
        switch self {
        case .newTrip:
            NotificationCenter.default.post(name: .openNewTrip, object: nil)
        case .today:
            NotificationCenter.default.post(name: .openToday, object: nil)
        }
    }
}

extension QuickActionRouter {
    /// `moss://shortcut/<action>` runs a quick action; anything else is an
    /// auth callback.
    static func handle(url: URL, auth: AuthClient) {
        Log.breadcrumb("incoming app link", category: "deeplink")

        if url.scheme == "moss", url.host == "shortcut",
           let actionName = url.pathComponents.last,
           let action = AppQuickAction(rawValue: actionName) {
            handle(action)
            return
        }

        Task { await auth.handle(callbackURL: url) }
    }
}

extension Notification.Name {
    static let openNewTrip = Notification.Name("moss.openNewTrip")
    static let openToday = Notification.Name("moss.openToday")
}
