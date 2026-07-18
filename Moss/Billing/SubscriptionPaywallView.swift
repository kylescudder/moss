import SwiftUI

struct SubscriptionPaywallView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var isPurchasing = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("Moss Supporter")
                        .font(.largeTitle.bold())
                    Text("Keep more journeys, notes, and shared plans together as Moss grows with every trip.")
                        .foregroundStyle(Theme.Colors.textSecondary)
                }

                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    PaywallRow(systemImage: "suitcase.fill", title: "Unlimited journeys")
                    PaywallRow(systemImage: "person.2.fill", title: "Ready for shared planning")
                    PaywallRow(systemImage: "bell.badge.fill", title: "Gentle reminders while you travel")
                }

                Spacer()

                PrimaryButton(
                    title: subscribeButtonTitle,
                    systemImage: "sparkles",
                    isLoading: isPurchasing
                ) {
                    Task { await purchase() }
                }

                Button("Restore purchases") {
                    Task { _ = await services.billing.restorePurchases() }
                }
                .frame(maxWidth: .infinity)

                if let message = services.billing.lastError {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding(Theme.Spacing.xl)
            .navigationTitle("Upgrade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await services.billing.loadProducts()
            }
        }
    }

    private var subscribeButtonTitle: String {
        if let displayPrice = services.billing.subscriptionProduct?.displayPrice {
            return "Subscribe for \(displayPrice)"
        }
        return "Subscribe"
    }

    private func purchase() async {
        isPurchasing = true
        defer { isPurchasing = false }
        if await services.billing.purchase() {
            dismiss()
        }
    }
}

private struct PaywallRow: View {
    let systemImage: String
    let title: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
    }
}
