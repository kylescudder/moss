import SwiftUI

struct TripEditorView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var draft = TripDraft()
    @State private var isSaving = false
    @State private var saveError: TripCreationError?
    @State private var showPaywall = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Trip") {
                    TextField("Title", text: $draft.title)
                    TextField("Destination", text: $draft.destination)
                    DatePicker("Starts", selection: $draft.startsAt, displayedComponents: .date)
                    DatePicker("Ends", selection: $draft.endsAt, displayedComponents: .date)
                }

                Section("Notes") {
                    TextEditor(text: $draft.notes)
                        .frame(minHeight: 120)
                }

                if let saveError {
                    Section {
                        Text(saveError.errorDescription ?? "Moss couldn't save this trip.")
                            .foregroundStyle(.red)
                        recoveryAction(for: saveError)
                    }
                }
            }
            .navigationTitle("New Trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(!draft.isValid || isSaving)
                }
            }
        }
        .sheet(isPresented: $showPaywall) {
            SubscriptionPaywallView()
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        saveError = nil

        switch await services.trips.create(draft) {
        case .success:
            dismiss()
        case .failure(.quotaReached):
            if services.billing.hasStoreKitEntitlement && !services.billing.isSubscribed {
                saveError = .subscriptionVerificationPending
            } else {
                saveError = .quotaReached
                showPaywall = true
            }
        case .failure(let error):
            saveError = error
        }
    }

    @ViewBuilder
    private func recoveryAction(for error: TripCreationError) -> some View {
        switch error {
        case .subscriptionVerificationPending:
            Button("Retry subscription verification") {
                Task { await services.billing.retryEntitlementVerification() }
            }
        case .authenticationRequired:
            Button("Refresh session") {
                Task {
                    if await services.auth.refreshSession() {
                        await save()
                    }
                }
            }
        case .connectivity:
            Button("Retry save") {
                Task { await save() }
            }
        case .quotaReached, .quotaSnapshotUnavailable, .serverValidation, .unknown:
            EmptyView()
        }
    }
}
