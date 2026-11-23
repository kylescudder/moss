import Foundation

enum TripCreationError: Error, Equatable, Identifiable, Sendable {
    case freeLimitReached
    case subscriptionVerificationPending
    case quotaSnapshotUnavailable
    case unauthenticated
    case networkFailure
    case serverValidationFailure
    case unknownFailure

    var id: String {
        switch self {
        case .freeLimitReached: "freeLimitReached"
        case .subscriptionVerificationPending: "subscriptionVerificationPending"
        case .quotaSnapshotUnavailable: "quotaSnapshotUnavailable"
        case .unauthenticated: "unauthenticated"
        case .networkFailure: "networkFailure"
        case .serverValidationFailure: "serverValidationFailure"
        case .unknownFailure: "unknownFailure"
        }
    }

    static func classify(
        _ error: Error,
        subscriptionState: SubscriptionAccessState
    ) -> TripCreationError {
        if let creationError = error as? TripCreationError {
            return creationError
        }

        if let apiError = error as? APIError {
            switch apiError.code {
            case "MX001":
                return subscriptionState == .verifying
                    ? .subscriptionVerificationPending
                    : .freeLimitReached
            case "MX002", "DX002":
                return .unauthenticated
            case "MX003", "MX004", "MX005", "42501":
                return .serverValidationFailure
            case "temporarily_unavailable":
                return .networkFailure
            default:
                return .serverValidationFailure
            }
        }

        let nsError = error as NSError
        if error is URLError || nsError.domain == NSURLErrorDomain {
            return .networkFailure
        }
        return .unknownFailure
    }
}

enum TripCreationFailurePresentation: Equatable, Sendable {
    case paywall
    case verification(title: String, message: String)
    case alert(title: String, message: String)

    static func forError(_ error: TripCreationError) -> TripCreationFailurePresentation {
        switch error {
        case .freeLimitReached:
            return .paywall
        case .subscriptionVerificationPending:
            return .verification(
                title: "Verifying subscription",
                message: "Apple has verified your subscription, but Moss is still confirming it with the server. Retry in a moment."
            )
        case .quotaSnapshotUnavailable:
            return .alert(
                title: "Finish syncing first",
                message: "Moss needs to download your trip allowance before you can create trips offline. Make sure you're online, wait for sync to finish, and try again."
            )
        case .unauthenticated:
            return .alert(
                title: "Sign in again",
                message: "Your session is no longer available. Sign in again, then retry saving this trip."
            )
        case .networkFailure:
            return .alert(
                title: "Couldn't save trip",
                message: "Please check your connection and try again."
            )
        case .serverValidationFailure:
            return .alert(
                title: "Couldn't save trip",
                message: "The server rejected this trip. Please retry or contact support if the problem continues."
            )
        case .unknownFailure:
            return .alert(
                title: "Couldn't save trip",
                message: "Something unexpected happened. Please try again."
            )
        }
    }
}

enum TripQuotaSnapshot {
    static func requireInitializedCount(_ lifetimeCount: Int?) throws -> Int {
        guard let lifetimeCount else {
            throw TripCreationError.quotaSnapshotUnavailable
        }
        return lifetimeCount
    }
}

struct TripCreationStatus: Decodable, Equatable, Sendable {
    let lifetimeCount: Int
    let freeLimit: Int
    let hasVerifiedEntitlement: Bool

    enum CodingKeys: String, CodingKey {
        case lifetimeCount = "lifetime_count"
        case freeLimit = "free_limit"
        case hasVerifiedEntitlement = "has_verified_entitlement"
    }
}

enum TripCreationAvailability: Equatable, Sendable {
    case allowed
    case limitReached
    case subscriptionVerificationPending
    case failed(TripCreationError)

    static func resolve(
        status: TripCreationStatus,
        subscriptionState: SubscriptionAccessState
    ) -> TripCreationAvailability {
        if status.hasVerifiedEntitlement || status.lifetimeCount < status.freeLimit {
            return .allowed
        }
        return subscriptionState == .verifying
            ? .subscriptionVerificationPending
            : .limitReached
    }
}
