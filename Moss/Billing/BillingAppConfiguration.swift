import Foundation

/// Moss's values for the shared billing core (`BillingRepository`,
/// `SubscriptionPaywallView`).
enum BillingAppConfiguration {
    static let productID = "app.moss.supporter.monthly"
    static let verificationPendingMessage =
        "Apple verified your subscription, but Moss is still confirming it with the server. Tap Retry verification in a moment."

    static let paywallHeadline = "Keep planning trips"
    static let paywallMessage =
        "Your first \(AppServices.freeTripLimit) trips are free. This is a lifetime allowance, so deleted trips still count. Subscribe to plan unlimited trips and itineraries."
    static func usageText(count: Int) -> String {
        "\(count) \(count == 1 ? "trip" : "trips") created"
    }

    static let privacyPolicyURL = URL(string: "https://moss.kylescudder.co.uk/privacy")!
    static let termsOfUseURL = URL(string: "https://moss.kylescudder.co.uk/terms")!
}
