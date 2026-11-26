import SwiftUI

struct ItineraryItemEditorView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    let trip: Trip
    private let itemToEdit: ItineraryItem?
    @State private var draft: ItineraryItemDraft
    @State private var isSaving = false
    @State private var saveCount = 0
    @State private var travelTimeRequest: TravelTimeRequest?

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
                    if draft.kind == .transport {
                        LocationSearchField(title: "From", text: $draft.locationName)
                        LocationSearchField(title: "To", text: $draft.destinationName)
                        Picker("Travel by", selection: $draft.transportMode) {
                            Text("Choose a mode").tag(TransportMode?.none)
                            ForEach(TransportMode.allCases) { mode in
                                Text(mode.label).tag(Optional(mode))
                            }
                        }
                    } else {
                        LocationSearchField(title: "Location", text: $draft.locationName)
                    }
                }

                Section("When") {
                    DatePicker("Starts", selection: $draft.startsAt)
                    DatePicker("Ends", selection: $draft.endsAt, in: draft.startsAt...)
                    if draft.kind == .transport {
                        Button("Calculate travel time", systemImage: "map") {
                            travelTimeRequest = draft.travelTimeRequest
                        }
                        .disabled(draft.travelTimeRequest == nil)
                        Text("Choose From, To and a travel mode to estimate your end time with Apple Maps. You can also set Ends yourself.")
                            .font(.footnote)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
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
            .sheet(item: $travelTimeRequest) { request in
                TransportTravelTimeView(request: request) { duration in
                    draft.applyTravelTime(duration, for: request)
                }
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
