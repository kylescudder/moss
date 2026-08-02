import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var services: AppServices
    @AppStorage("appearance") private var appearance: Appearance = .system
    @State private var showSignOutConfirm = false
    @State private var showDeleteConfirm = false
    @State private var showFinalDeleteConfirm = false
    @State private var deleteError: String?
    @State private var isDeleting = false
    @State private var showPaywall = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(Appearance.allCases) { appearance in
                        Text(appearance.label).tag(appearance)
                    }
                }
            }

            Section("Profile") {
                if let profile = services.profile.profile {
                    LabeledContent("Display name", value: profile.displayName ?? "Not set")
                } else if services.profile.isLoading {
                    ProgressView()
                }
                NavigationLink("Edit display name") {
                    EditDisplayNameView(initial: services.profile.profile?.displayName ?? "")
                }
            }

            Section("Notifications") {
                NotificationSettingsRow()
            }

            Section {
                LabeledContent("Plan", value: subscriptionPlanLabel)
                if services.billing.hasStoreKitEntitlement {
                    Button("Manage subscription") {
                        Task { await services.billing.manageSubscriptions() }
                    }
                } else {
                    Button("Upgrade to Supporter Monthly") {
                        showPaywall = true
                    }
                }
                Button("Restore purchases") {
                    Task { _ = await services.billing.restorePurchases() }
                }
                if case .verificationFailed(let message) = services.billing.entitlementVerificationState {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    Button("Retry subscription verification") {
                        Task { await services.billing.retryEntitlementVerification() }
                    }
                }
                if let message = services.billing.lastError {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Subscription")
            } footer: {
                Text("Free accounts can create \(AppServices.freeTripCreationLimit) trips over the lifetime of the account. Trips created while subscribed also count toward lifetime usage, and deleting a trip does not restore a free creation.")
            }

            Section("Account") {
                if case let .signedIn(_, email) = services.auth.state, let email {
                    LabeledContent("Signed in as", value: email)
                }
                Button("Sign out", role: .destructive) {
                    showSignOutConfirm = true
                }
                Button("Delete account", role: .destructive) {
                    showDeleteConfirm = true
                }
                .disabled(isDeleting)
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)
                Link("Support", destination: URL(string: "https://getmoss.app/support")!)
                Link("Privacy Policy", destination: URL(string: "https://getmoss.app/privacy")!)
            }
        }
        .navigationTitle("Settings")
        .task {
            await services.profile.refresh()
            await services.notifications.refreshAuthorizationStatus()
        }
        .sheet(isPresented: $showPaywall) {
            SubscriptionPaywallView()
        }
        .alert("Sign out of Moss?", isPresented: $showSignOutConfirm) {
            Button("Sign out", role: .destructive) {
                Task { await services.auth.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete your Moss account?", isPresented: $showDeleteConfirm) {
            Button("Continue", role: .destructive) {
                showFinalDeleteConfirm = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes your trips, saved details, devices, subscription mirror, and profile. This cannot be undone.")
        }
        .alert("Are you absolutely sure?", isPresented: $showFinalDeleteConfirm) {
            Button("Delete forever", role: .destructive) {
                Task { await deleteAccount() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn't delete account", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        ), presenting: deleteError) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text($0) }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }

    private var subscriptionPlanLabel: String {
        switch services.billing.entitlementVerificationState {
        case .verified:
            return "Supporter Monthly"
        case .verifying:
            return "Verifying subscription"
        case .verificationFailed:
            return "Verification needed"
        case .notSubscribed:
            return "Free"
        }
    }

    private func deleteAccount() async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await services.auth.deleteAccount()
        } catch {
            deleteError = error.localizedDescription
        }
    }
}

private struct NotificationSettingsRow: View {
    @ObservedObject private var notifications = NotificationManager.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch notifications.authorizationStatus {
        case .authorized, .ephemeral, .provisional:
            Label("Push notifications allowed", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case .denied:
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Label("Push notifications disabled in iOS Settings", systemImage: "xmark.seal")
                    .foregroundStyle(.red)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        openURL(url)
                    }
                }
            }
        case .notDetermined:
            Button("Turn on push notifications") {
                Task { await notifications.requestAuthorization() }
            }
        @unknown default:
            Text("Push notification status unknown")
        }
    }
}

private struct EditDisplayNameView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String

    init(initial: String) {
        self._displayName = State(initialValue: initial)
    }

    var body: some View {
        Form {
            Section("Profile") {
                TextField("Display name", text: $displayName)
            }
        }
        .navigationTitle("Display Name")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        await services.profile.updateDisplayName(displayName)
                        dismiss()
                    }
                }
            }
        }
    }
}
