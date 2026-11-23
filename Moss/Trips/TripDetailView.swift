import SwiftUI

struct TripDetailView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    let tripID: UUID
    @State private var showAddItem = false
    @State private var showEditTrip = false
    @State private var itemToEdit: ItineraryItem?
    @State private var showDeleteConfirm = false

    private var trip: Trip? {
        services.trips.trips.first { $0.id == tripID }
    }

    private var days: [(Date, [ItineraryItem])] {
        let calendar = Calendar.current
        let items = services.itinerary.items(for: tripID)
        let groups = Dictionary(grouping: items) { item in
            calendar.startOfDay(for: item.startsAt ?? trip?.startsAt ?? Date())
        }
        return groups.keys.sorted().map { ($0, groups[$0, default: []]) }
    }

    var body: some View {
        Group {
            if let trip {
                content(for: trip)
            } else {
                EmptyState(
                    systemImage: "suitcase",
                    title: "Trip unavailable",
                    message: "This trip was deleted or hasn't synced to this device yet."
                )
            }
        }
        .background(Theme.Colors.background)
        .navigationTitle(trip?.title ?? "Trip")
        .navigationBarTitleDisplayMode(.large)
    }

    private func content(for trip: Trip) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Label(trip.destination, systemImage: "mappin.and.ellipse")
                        .font(.title3.weight(.semibold))
                    if let range = trip.dateRangeText {
                        Label(range, systemImage: "calendar")
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                    if let notes = trip.notes {
                        Text(notes)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)
            }

            if days.isEmpty {
                Section {
                    EmptyState(
                        systemImage: "calendar.badge.plus",
                        title: "Nothing planned yet",
                        message: "Add flights, stays, meals, activities and notes.",
                        actionTitle: "Add a plan",
                        action: { showAddItem = true }
                    )
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(days, id: \.0) { day, items in
                    Section(day.formatted(.dateTime.weekday(.wide).day().month(.wide))) {
                        ForEach(items) { item in
                            Button {
                                itemToEdit = item
                            } label: {
                                ItineraryItemRow(item: item)
                            }
                            .foregroundStyle(Theme.Colors.textPrimary)
                        }
                        .onDelete { offsets in
                            Task {
                                for index in offsets {
                                    await services.itinerary.softDelete(items[index])
                                }
                            }
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddItem = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add a plan")
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Edit trip", systemImage: "pencil") { showEditTrip = true }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Delete trip", systemImage: "trash", role: .destructive) {
                    showDeleteConfirm = true
                }
            }
        }
        .sheet(isPresented: $showAddItem) {
            ItineraryItemEditorView(trip: trip)
        }
        .sheet(item: $itemToEdit) { item in
            ItineraryItemEditorView(trip: trip, item: item)
        }
        .sheet(isPresented: $showEditTrip) {
            TripEditorView(trip: trip)
        }
        .alert("Delete \(trip.title)?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                Task {
                    await services.trips.softDelete(trip)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The trip and its plans are removed from every device. Deleting a trip doesn't restore a free trip.")
        }
    }
}

struct ItineraryItemRow: View {
    let item: ItineraryItem
    var showsDate = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: item.kind.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.Colors.accent)
                .frame(width: Theme.Spacing.iconRow)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(item.title)
                    .font(.headline)
                if let locationName = item.locationName {
                    Text(locationName)
                        .footnoteSecondary()
                }
                if let timeText = item.timeText {
                    Text(showsDate ? "\(item.startsAt?.formatted(date: .abbreviated, time: .omitted) ?? "") \(timeText)" : timeText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }
}
