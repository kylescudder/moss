import Combine
import Foundation

/// Moss's quick actions for the shared `QuickActionRouter`. Keep widgets,
/// App Intents, URL path names and raw values in sync.
enum AppQuickAction: String, CaseIterable {
    case newTrip
    case today

    /// Where an action waits until the UI is ready. Keep the key stable.
    static let pendingStorageKey = "moss.pendingQuickAction"

    /// Hands the action to `MainTabView` through `QuickActionInbox`, which
    /// keeps it until the signed-in tabs exist to take it.
    @MainActor
    func route() {
        QuickActionInbox.shared.deliver(self)
    }
}

/// Holds the latest routed quick action until `MainTabView` takes it.
///
/// The shared router replays a cold-launch action as soon as `RootView`
/// appears, which is while auth is still bootstrapping (or the user is
/// signed out) and `MainTabView` doesn't exist yet. `actions` hands a waiting
/// action to each new subscriber, then every later one, so the tabs pick it
/// up when they appear instead of it being posted to nobody.
@MainActor
final class QuickActionInbox {
    static let shared = QuickActionInbox()

    private(set) var pending: AppQuickAction?
    private let arrivals = PassthroughSubject<Void, Never>()

    /// Each waiting action, delivered once.
    var actions: AnyPublisher<AppQuickAction, Never> {
        arrivals
            .prepend(())
            .compactMap { _ in MainActor.assumeIsolated { QuickActionInbox.shared.take() } }
            .eraseToAnyPublisher()
    }

    func deliver(_ action: AppQuickAction) {
        pending = action
        arrivals.send()
    }

    /// Returns the waiting action and clears it, so it runs once.
    func take() -> AppQuickAction? {
        defer { pending = nil }
        return pending
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
