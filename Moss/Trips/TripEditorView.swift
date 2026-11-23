import SwiftUI

/// Creates a trip (through the lifetime creation allowance) or edits one.
struct TripEditorView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    private let tripToEdit: Trip?
    @State private var draft: TripDraft
    @State private var isSaving = false
    @State private var showPaywall = false
    @State private var creationFailure: TripCreationError?
    @State private var saveCount = 0

    init(trip: Trip? = nil) {
        tripToEdit = trip
        _draft = State(initialValue: trip.map(TripDraft.init(trip:)) ?? TripDraft())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Trip") {
                    TextField("Title", text: $draft.title)
                        .textInputAutocapitalization(.words)
                    TextField("Destination", text: $draft.destination)
                        .textInputAutocapitalization(.words)
                }

                Section("Dates") {
                    DatePicker("Starts", selection: $draft.startsAt, displayedComponents: .date)
                    DatePicker("Ends", selection: $draft.endsAt, in: draft.startsAt..., displayedComponents: .date)
                }

                Section("Notes") {
                    TextField("Bookings, ideas, who's coming", text: $draft.notes, axis: .vertical)
                        .lineLimit(4...10)
                }
            }
            .navigationTitle(tripToEdit == nil ? "New trip" : "Edit trip")
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
            .onChange(of: draft.startsAt) { _, start in
                if draft.endsAt < start { draft.endsAt = start }
            }
            .sheet(isPresented: $showPaywall) {
                SubscriptionPaywallView()
            }
            .alert(item: $creationFailure) { error in
                creationAlert(for: error)
            }
            .sensoryFeedback(.success, trigger: saveCount)
        }
    }

    private func save() async {
        guard draft.isValid, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        if let tripToEdit {
            await services.trips.update(tripToEdit, with: draft)
        } else {
            switch await services.canCreateNewTrip() {
            case .allowed:
                break
            case .limitReached:
                showPaywall = true
                return
            case .subscriptionVerificationPending:
                handleCreationError(.subscriptionVerificationPending)
                return
            case .failed(let error):
                handleCreationError(error)
                return
            }

            do {
                try await services.trips.create(draft)
            } catch let error as TripCreationError {
                handleCreationError(error)
                return
            } catch {
                handleCreationError(.unknownFailure)
                return
            }
        }
        saveCount += 1
        dismiss()
    }

    private func handleCreationError(_ error: TripCreationError) {
        if case .paywall = TripCreationFailurePresentation.forError(error) {
            showPaywall = true
        } else {
            creationFailure = error
        }
    }

    private func creationAlert(for error: TripCreationError) -> Alert {
        switch TripCreationFailurePresentation.forError(error) {
        case .paywall:
            return Alert(title: Text("Free trip limit reached"))
        case .verification(let title, let message):
            return Alert(
                title: Text(title),
                message: Text(message),
                primaryButton: .default(Text("Retry")) {
                    Task {
                        await services.billing.syncEntitlements()
                        await save()
                    }
                },
                secondaryButton: .cancel()
            )
        case .alert(let title, let message):
            return Alert(
                title: Text(title),
                message: Text(message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}
