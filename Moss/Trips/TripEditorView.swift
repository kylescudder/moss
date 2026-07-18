import SwiftUI

struct TripEditorView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var draft = TripDraft()
    @State private var isSaving = false

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

                if let message = services.trips.lastError {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
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
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        if await services.trips.create(draft) != nil {
            dismiss()
        }
    }
}

