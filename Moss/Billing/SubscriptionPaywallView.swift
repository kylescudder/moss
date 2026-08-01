import SwiftUI

struct SubscriptionPaywallView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss

    @State private var isPurchasing = false
    @State private var isRestoring = false
    @State private var createdTripCount: Int?

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: Theme.Spacing.xl) {
                        Spacer(minLength: Theme.Spacing.lg)

                        Image("AppLogoIcon")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 78, height: 78)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))

                        VStack(spacing: Theme.Spacing.sm) {
                            Text("Keep planning your trips")
                                .font(.title2.weight(.semibold))
                                .multilineTextAlignment(.center)
                            Text("Create \(AppServices.freeTripCreationLimit) trips free over the lifetime of your account. Deleting a trip doesn't restore a free creation. Subscribe for unlimited trip creation while your subscription is active.")
                                .font(.body)
                                .foregroundStyle(Theme.Colors.textSecondary)
                                .multilineTextAlignment(.center)
                        }

                        VStack(spacing: Theme.Spacing.sm) {
                            PrimaryButton(
                                title: subscribeTitle,
                                systemImage: "checkmark.seal.fill",
                                isLoading: isPurchasing,
                                action: { Task { await subscribe() } }
                            )
                            .disabled(
                                isRestoring
                                    || services.billing.hasStoreKitEntitlement
                                    || (services.billing.isLoadingProducts
                                        && services.billing.subscriptionProduct == nil)
                            )

                            Button {
                                Task { await restore() }
                            } label: {
                                if isRestoring {
                                    ProgressView()
                                } else {
                                    Text("Restore purchases")
                                }
                            }
                            .disabled(isRestoring || isPurchasing)
                        }

                        entitlementVerificationStatus

                        if services.billing.isLoadingProducts {
                            ProgressView()
                        } else if services.billing.subscriptionProduct == nil {
                            Text("Subscription details are unavailable. Tap Subscribe to try again.")
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                        } else if let message = services.billing.lastError {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                        }

                        if let createdTripCount {
                            Text(tripUsageText(createdTripCount))
                                .font(.footnote)
                                .foregroundStyle(Theme.Colors.textTertiary)
                        }

                        subscriptionDisclosure

                        Spacer(minLength: Theme.Spacing.lg)
                    }
                    .padding(Theme.Spacing.xl)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
                .background(Theme.Colors.background)
            }
            .navigationTitle("Supporter Monthly")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                }
            }
            .task {
                await services.billing.loadProducts()
                await services.billing.syncEntitlements()
                await loadCount()
                if services.billing.isSubscribed {
                    dismiss()
                }
            }
            .onChange(of: services.billing.isSubscribed) { _, subscribed in
                if subscribed { dismiss() }
            }
        }
    }

    private var subscribeTitle: String {
        guard let product = services.billing.subscriptionProduct else {
            return "Subscribe"
        }
        return "Subscribe \(product.displayPrice) / month"
    }

    @ViewBuilder
    private var entitlementVerificationStatus: some View {
        switch services.billing.entitlementVerificationState {
        case .verifying:
            ProgressView("Confirming your subscription with Moss…")
                .font(.footnote)
        case .verificationFailed(let message):
            VStack(spacing: Theme.Spacing.xs) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                Button("Retry verification") {
                    Task { await services.billing.retryEntitlementVerification() }
                }
                .font(.footnote.weight(.semibold))
            }
        case .notSubscribed, .verified:
            EmptyView()
        }
    }

    @ViewBuilder
    private var subscriptionDisclosure: some View {
        VStack(spacing: Theme.Spacing.xs) {
            Text("Supporter Monthly")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.Colors.textSecondary)
            Text(subscriptionDetailText)
                .font(.footnote)
                .foregroundStyle(Theme.Colors.textTertiary)
                .multilineTextAlignment(.center)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Spacing.sm) {
                    Link("Privacy Policy", destination: Self.privacyPolicyURL)
                    Text("•")
                        .foregroundStyle(Theme.Colors.textTertiary)
                    Link("Terms of Use", destination: Self.termsOfUseURL)
                }
                .fixedSize(horizontal: true, vertical: false)

                VStack(spacing: Theme.Spacing.xs) {
                    Link("Privacy Policy", destination: Self.privacyPolicyURL)
                    Link("Terms of Use", destination: Self.termsOfUseURL)
                }
            }
            .font(.footnote.weight(.semibold))
        }
        .padding(.top, Theme.Spacing.sm)
    }

    private var subscriptionDetailText: String {
        guard let product = services.billing.subscriptionProduct else {
            return "Monthly auto-renewable subscription. Payment is charged to your Apple ID after purchase confirmation. Paid trip creation begins after Moss securely verifies the transaction with Apple."
        }
        return "Monthly auto-renewable subscription: \(product.displayPrice) per month. Payment is charged to your Apple ID after purchase confirmation. Paid trip creation begins after Moss securely verifies the transaction with Apple."
    }

    private static let privacyPolicyURL = URL(string: "https://getmoss.app/privacy")!
    private static let termsOfUseURL = URL(string: "https://getmoss.app/terms")!

    private func subscribe() async {
        isPurchasing = true
        defer { isPurchasing = false }
        if await services.billing.purchase() {
            dismiss()
        }
    }

    private func restore() async {
        isRestoring = true
        defer { isRestoring = false }
        if await services.billing.restorePurchases() {
            dismiss()
        }
    }

    private func loadCount() async {
        createdTripCount = try? await services.trips.lifetimeTripCount()
    }

    private func tripUsageText(_ count: Int) -> String {
        if count <= AppServices.freeTripCreationLimit {
            return "\(count) of \(AppServices.freeTripCreationLimit) lifetime free trip creations used"
        }
        return "\(count) lifetime trip creations used"
    }
}
