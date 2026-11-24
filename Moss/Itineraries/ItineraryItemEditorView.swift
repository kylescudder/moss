import SwiftUI

struct ItineraryItemEditorView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    let trip: Trip
    private let itemToEdit: ItineraryItem?
    @State private var draft: ItineraryItemDraft
    @State private var isSaving = false
    @State private var saveCount = 0

    init(trip: Trip, item: ItineraryItem? = nil) {
        self.trip = trip
        itemToEdit = item
        let start = trip.isActive() ? Date() : (trip.startsAt ?? Date())
        _draft = State(initialValue: item.map(ItineraryItemDraft.init(item:)) ?? ItineraryItemDraft(startsAt: start))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    Picker("Type", selection: $draft.kind) {
                        ForEach(ItineraryItemKind.allCases) { kind in
                            Label(kind.label, systemImage: kind.symbol).tag(kind)
                        }
                    }
                    TextField("Title", text: $draft.title)
                    TextField("Location", text: $draft.locationName)
                }

                Section("When") {
                    DatePicker("Starts", selection: $draft.startsAt)
                    DatePicker("Ends", selection: $draft.endsAt, in: draft.startsAt...)
                }

                Section("Notes") {
                    TextField("Confirmation numbers, addresses, reminders", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...8)
                }

                if let message = services.itinerary.lastError {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(itemToEdit == nil ? "Add a plan" : "Edit plan")
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
            .onChange(of: draft.startsAt) { old, start in
                let duration = max(draft.endsAt.timeIntervalSince(old), 0)
                draft.endsAt = start.addingTimeInterval(duration)
            }
            .sensoryFeedback(.success, trigger: saveCount)
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let saved = if let itemToEdit {
            await services.itinerary.update(itemToEdit, with: draft)
        } else {
            await services.itinerary.create(draft, trip: trip)
        }
        if saved {
            saveCount += 1
            dismiss()
        }
    }
}
