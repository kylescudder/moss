import Foundation
import StoreKit
import UIKit

@MainActor
final class BillingRepository: ObservableObject {
    static let supporterMonthlyProductID = "app.moss.supporter.monthly"

    @Published private(set) var subscriptionProduct: Product?
    @Published private(set) var isLoadingProducts = false
    @Published private(set) var entitlementVerificationState: EntitlementVerificationState = .notSubscribed
    @Published private(set) var hasStoreKitEntitlement = false
    @Published var lastError: String?

    private let auth: AuthClient
    private var transactionTask: Task<Void, Never>?
    private var mirrorRetryTask: Task<Void, Never>?
    private var automaticRetryAttempt = 0

    var isSubscribed: Bool {
        entitlementVerificationState == .verified
    }

    init(auth: AuthClient) {
        self.auth = auth
    }

    deinit {
        transactionTask?.cancel()
        mirrorRetryTask?.cancel()
    }

    func start() {
        transactionTask?.cancel()
        transactionTask = Task { [weak self] in
            guard let self else { return }
            for await result in Transaction.updates {
                await self.handle(result)
            }
        }
        Task {
            await loadProducts()
            await syncEntitlements()
        }
    }

    func resetForSignOut() {
        mirrorRetryTask?.cancel()
        mirrorRetryTask = nil
        automaticRetryAttempt = 0
        hasStoreKitEntitlement = false
        entitlementVerificationState = .notSubscribed
        lastError = nil
    }

    func loadProducts() async {
        lastError = nil
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            let products = try await Product.products(for: [Self.supporterMonthlyProductID])
            subscriptionProduct = products.first
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "billing.products")
        }
    }

    @discardableResult
    func purchase() async -> Bool {
        guard let product = subscriptionProduct else {
            await loadProducts()
            guard subscriptionProduct != nil else { return false }
            return await purchase()
        }
        guard let userID = auth.currentUserID else { return false }

        do {
            let result = try await product.purchase(options: [.appAccountToken(userID)])
            switch result {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    lastError = "The purchase could not be verified."
                    return false
                }
                hasStoreKitEntitlement = transaction.isActiveSubscriptionEntitlement
                entitlementVerificationState = .verifying
                if await mirror(transaction, jwsRepresentation: verification.jwsRepresentation) {
                    entitlementVerificationState = .verified
                    automaticRetryAttempt = 0
                    await transaction.finish()
                    return true
                }
                markVerificationFailed()
                return false
            case .userCancelled, .pending:
                return false
            @unknown default:
                return false
            }
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "billing.purchase")
            return false
        }
    }

    @discardableResult
    func restorePurchases() async -> Bool {
        do {
            try await AppStore.sync()
            await syncEntitlements()
            return isSubscribed
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "billing.restore")
            return false
        }
    }

    func manageSubscriptions() async {
        do {
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
                return
            }
            try await AppStore.showManageSubscriptions(in: scene)
            await syncEntitlements()
        } catch {
            lastError = error.localizedDescription
            Log.error(error, category: "billing.manageSubscriptions")
        }
    }

    func syncEntitlements() async {
        var activeTransaction: (transaction: Transaction, jwsRepresentation: String)?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == Self.supporterMonthlyProductID else { continue }
            if transaction.isActiveSubscriptionEntitlement {
                activeTransaction = (transaction, result.jwsRepresentation)
                break
            }
        }

        guard let activeTransaction else {
            mirrorRetryTask?.cancel()
            mirrorRetryTask = nil
            automaticRetryAttempt = 0
            hasStoreKitEntitlement = false
            entitlementVerificationState = .notSubscribed
            return
        }

        hasStoreKitEntitlement = true
        entitlementVerificationState = .verifying
        if await mirror(
            activeTransaction.transaction,
            jwsRepresentation: activeTransaction.jwsRepresentation
        ) {
            mirrorRetryTask?.cancel()
            mirrorRetryTask = nil
            automaticRetryAttempt = 0
            entitlementVerificationState = .verified
            await activeTransaction.transaction.finish()
        } else {
            markVerificationFailed()
        }
    }

    func retryEntitlementVerification() async {
        mirrorRetryTask?.cancel()
        mirrorRetryTask = nil
        automaticRetryAttempt = 0
        await syncEntitlements()
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        guard transaction.productID == Self.supporterMonthlyProductID else { return }
        hasStoreKitEntitlement = transaction.isActiveSubscriptionEntitlement
        guard transaction.isActiveSubscriptionEntitlement else {
            mirrorRetryTask?.cancel()
            mirrorRetryTask = nil
            automaticRetryAttempt = 0
            entitlementVerificationState = .notSubscribed
            await transaction.finish()
            return
        }

        entitlementVerificationState = .verifying
        if await mirror(transaction, jwsRepresentation: result.jwsRepresentation) {
            automaticRetryAttempt = 0
            entitlementVerificationState = .verified
            await transaction.finish()
        } else {
            markVerificationFailed()
        }
    }

    private func mirror(_ transaction: Transaction, jwsRepresentation: String) async -> Bool {
        guard transaction.productID == Self.supporterMonthlyProductID,
              transaction.isActiveSubscriptionEntitlement else { return false }

        var finalError: Error = BillingSyncError.missingAccessToken
        for attempt in 0..<3 {
            do {
                try await mirrorOnce(jwsRepresentation: jwsRepresentation)
                lastError = nil
                return true
            } catch is CancellationError {
                return false
            } catch {
                finalError = error
                if attempt < 2 {
                    try? await Task.sleep(for: .milliseconds(400 * (1 << attempt)))
                }
            }
        }

        lastError = finalError.localizedDescription
        Log.error(finalError, category: "billing.syncTransaction")
        return false
    }

    private func mirrorOnce(jwsRepresentation: String) async throws {
        guard let token = await auth.currentAccessToken() else {
            throw BillingSyncError.missingAccessToken
        }

        let url = AppSecrets.supabaseURL
            .appendingPathComponent("functions")
            .appendingPathComponent("v1")
            .appendingPathComponent("iap-sync-transaction")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(AppSecrets.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONEncoder().encode(TransactionSyncRequest(
            signedTransactionInfo: jwsRepresentation,
            source: "ios"
        ))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BillingSyncError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BillingSyncError.badStatus(
                http.statusCode,
                String(data: data, encoding: .utf8)
            )
        }
    }

    private func markVerificationFailed() {
        entitlementVerificationState = .verificationFailed(
            "Your subscription is active with Apple, but Moss hasn't confirmed it yet. Your paid trip allowance will unlock after verification succeeds."
        )
        scheduleAutomaticMirrorRetry()
    }

    private func scheduleAutomaticMirrorRetry() {
        mirrorRetryTask?.cancel()
        automaticRetryAttempt += 1
        let delay = min(60, 5 * (1 << min(automaticRetryAttempt - 1, 3)))
        mirrorRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.syncEntitlements()
        }
    }
}

enum EntitlementVerificationState: Equatable {
    case notSubscribed
    case verifying
    case verified
    case verificationFailed(String)

    var canRetry: Bool {
        if case .verificationFailed = self { return true }
        return false
    }
}

private struct TransactionSyncRequest: Encodable {
    let signedTransactionInfo: String
    let source: String
}

private enum BillingSyncError: LocalizedError {
    case missingAccessToken
    case invalidResponse
    case badStatus(Int, String?)

    var errorDescription: String? {
        switch self {
        case .missingAccessToken:
            return "Sign in again to verify your subscription."
        case .invalidResponse:
            return "Moss received an invalid subscription verification response."
        case .badStatus(let status, let body):
            let detail = body?.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Subscription verification failed with status \(status)\(detail.map { ": \($0)" } ?? ".")"
        }
    }
}

private extension Transaction {
    var isActiveSubscriptionEntitlement: Bool {
        guard revocationDate == nil else { return false }
        if let expirationDate {
            return expirationDate > Date()
        }
        return true
    }
}
