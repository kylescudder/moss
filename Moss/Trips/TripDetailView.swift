import SwiftUI

struct TripDetailView: View {
    @EnvironmentObject private var services: AppServices
    let trip: Trip
    @State private var showAddItem = false

    private var groupedItems: [(Date, [ItineraryItem])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: services.itinerary.items(for: trip)) { item in
            calendar.startOfDay(for: item.startsAt ?? trip.startsAt ?? Date())
        }
        return groups.keys.sorted().map { ($0, groups[$0, default: []]) }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text(trip.destination)
                        .font(.title3.weight(.semibold))
                    if let range = trip.dateRangeText {
                        Label(range, systemImage: "calendar")
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                    if let notes = trip.notes, !notes.isEmpty {
                        Text(notes)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)
            }

            if groupedItems.isEmpty {
                EmptyState(
                    title: "No Itinerary Items",
                    message: "Add flights, stays, meals, activities, and notes.",
                    systemImage: "calendar.badge.plus"
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(groupedItems, id: \.0) { day, items in
                    Section(day.formatted(date: .abbreviated, time: .omitted)) {
                        ForEach(items) { item in
                            ItineraryItemRow(item: item)
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
        .navigationTitle(trip.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddItem = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add itinerary item")
            }
        }
        .task {
            await services.itinerary.refresh(tripID: trip.id)
        }
        .refreshable {
            await services.itinerary.refresh(tripID: trip.id)
        }
        .sheet(isPresented: $showAddItem) {
            ItineraryItemEditorView(trip: trip)
        }
    }
}

struct ItineraryItemRow: View {
    let item: ItineraryItem

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: item.kind.symbol)
                .foregroundStyle(Theme.Colors.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(item.title)
                    .font(.headline)
                if let locationName = item.locationName, !locationName.isEmpty {
                    Text(locationName)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                if let timeText = item.timeText {
                    Text(timeText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }
}

