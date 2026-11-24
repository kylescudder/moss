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
    @State private var successCount = 0
    @State private var errorCount = 0
    @State private var showPaywall = false
    @State private var showReauthentication = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0) }
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

            Section {
                NavigationLink {
                    AllTripsSharingView()
                } label: {
                    Label("Share all my trips", systemImage: "person.2")
                }
            } header: {
                Text("Sharing")
            } footer: {
                Text("To share one trip, open it and tap Share.")
            }

            Section("Notifications") {
                PushAuthorizationRow()
            }

            Section {
                LabeledContent("Plan", value: subscriptionPlanLabel)
                if services.billing.isSubscribed {
                    Button("Manage subscription") {
                        Task { await services.billing.manageSubscriptions() }
                    }
                } else if services.billing.isVerifyingSubscription {
                    Button("Retry subscription verification") {
                        Task { await services.billing.syncEntitlements() }
                    }
                    Button("Manage subscription") {
                        Task { await services.billing.manageSubscriptions() }
                    }
                } else {
                    Button("Upgrade to Supporter Monthly") {
                        showPaywall = true
                    }
                }
                Button("Restore purchases") {
                    Task { await services.billing.restorePurchases() }
                }
                if let message = services.billing.lastError {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Subscription")
            } footer: {
                Text("Free accounts can create up to \(AppServices.freeTripLimit) lifetime trips; deleted trips still count. Manage subscription opens Apple's system sheet, where you can cancel or change the subscription.")
            }

            Section("Account") {
                if services.auth.requiresReauthentication {
                    Text("Sign in again with your original account to sync. Your offline changes are kept on this device.")
                    Button("Sign in to sync") { showReauthentication = true }
                }
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

            Section("Offline sync") {
                LabeledContent("Status", value: syncStatusLabel)
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)
                Link("Privacy Policy", destination: BillingAppConfiguration.privacyPolicyURL)
                Link("Terms of Use", destination: BillingAppConfiguration.termsOfUseURL)
                Link("Support", destination: URL(string: "https://growmoss.app/support")!)
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showReauthentication) { NavigationStack { SignInView() } }
        .onChange(of: services.auth.requiresReauthentication) { _, required in
            if !required { showReauthentication = false }
        }
        .alert("Sign out of Moss?", isPresented: $showSignOutConfirm) {
            Button("Sign out") {
                Task { await services.auth.signOut() }
            }
            Button("Sign out and remove local data", role: .destructive) {
                Task { await services.auth.signOut(removeLocalData: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Signing out keeps your offline changes on this device. Removing local data also deletes changes that have not synced. Data already saved to your account is kept.")
        }
        .alert("Delete your Moss account?", isPresented: $showDeleteConfirm) {
            Button("Continue", role: .destructive) {
                showFinalDeleteConfirm = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes your trips, itineraries, devices and account. This cannot be undone.")
        }
        .alert("Are you absolutely sure?", isPresented: $showFinalDeleteConfirm) {
            Button("Delete forever", role: .destructive) {
                Task { await deleteAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All your data will be deleted immediately.")
        }
        .alert("Couldn't delete account", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        ), presenting: deleteError) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text($0) }
        .sensoryFeedback(.success, trigger: successCount)
        .sensoryFeedback(.error, trigger: errorCount)
        .sheet(isPresented: $showPaywall) {
            SubscriptionPaywallView()
        }
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    private var subscriptionPlanLabel: String {
        switch services.billing.subscriptionState {
        case .free: "Free"
        case .verifying: "Verifying Supporter"
        case .active: "Supporter Monthly"
        }
    }

    private var syncStatusLabel: String {
        if services.sync.pendingUploadCount > 0 {
            let count = services.sync.pendingUploadCount
            return "\(count) change\(count == 1 ? "" : "s") queued"
        }
        switch services.sync.status {
        case .idle: return "Waiting"
        case .connecting: return "Connecting"
        case .connected: return "Up to date"
        case .offline: return "Offline — changes will queue"
        case .error: return "Needs attention"
        }
    }

    private func deleteAccount() async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await services.auth.deleteAccount()
            successCount += 1
        } catch {
            deleteError = error.localizedDescription
            errorCount += 1
        }
    }
}

private struct EditDisplayNameView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var didSeed = false
    @State private var isSaving = false
    @State private var saveCount = 0

    init(initial: String) {
        self._name = State(initialValue: initial)
        self._didSeed = State(initialValue: !initial.isEmpty)
    }

    var body: some View {
        Form {
            TextField("Display name", text: $name)
                .textContentType(.name)
        }
        .navigationTitle("Display name")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        isSaving = true
                        await services.profile.updateDisplayName(name.trimmingCharacters(in: .whitespaces))
                        isSaving = false
                        saveCount += 1
                        dismiss()
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            }
        }
        .sensoryFeedback(.success, trigger: saveCount)
        .task(id: services.profile.profile?.displayName) {
            if !didSeed, let value = services.profile.profile?.displayName, !value.isEmpty {
                name = value
                didSeed = true
            }
        }
    }
}
