import SwiftUI

/// A plan shown read-only, for people who can view a shared trip but not edit it.
struct ItineraryItemDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let item: ItineraryItem

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    LabeledContent("Type") {
                        Label(item.kind.label, systemImage: item.kind.symbol)
                    }
                    LabeledContent("Title", value: item.title)
                    if let locationName = item.locationName {
                        LabeledContent("Location", value: locationName)
                    }
                }

                Section("When") {
                    if let startsAt = item.startsAt {
                        LabeledContent("Starts", value: startsAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let endsAt = item.endsAt {
                        LabeledContent("Ends", value: endsAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }

                if let notes = item.notes {
                    Section("Notes") {
                        Text(notes)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
