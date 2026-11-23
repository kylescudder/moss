import SwiftUI

struct TripsListView: View {
    @EnvironmentObject private var services: AppServices
    @State private var showNewTrip = false

    var body: some View {
        Group {
            if services.trips.trips.isEmpty {
                if services.trips.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyState(
                        systemImage: "suitcase",
                        title: "No trips yet",
                        message: "Create a trip to start building a day-by-day itinerary.",
                        actionTitle: "New trip",
                        action: { showNewTrip = true }
                    )
                }
            } else {
                List {
                    section("Happening now", trips: services.trips.currentTrips)
                    section("Upcoming", trips: services.trips.upcomingTrips)
                    section("Past", trips: services.trips.pastTrips)
                }
            }
        }
        .background(Theme.Colors.background)
        .navigationTitle("Trips")
        .navigationDestination(for: Trip.self) { trip in
            TripDetailView(tripID: trip.id)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showNewTrip = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New trip")
            }
        }
        .refreshable { await services.refreshAll() }
        .sheet(isPresented: $showNewTrip) {
            TripEditorView()
        }
    }

    @ViewBuilder
    private func section(_ title: String, trips: [Trip]) -> some View {
        if !trips.isEmpty {
            Section(title) {
                ForEach(trips) { trip in
                    NavigationLink(value: trip) {
                        TripRow(trip: trip, itemCount: services.itinerary.items(for: trip.id).count)
                    }
                }
                .onDelete { offsets in
                    Task {
                        for index in offsets {
                            await services.trips.softDelete(trips[index])
                        }
                    }
                }
            }
        }
    }
}

struct TripRow: View {
    let trip: Trip
    var itemCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(trip.title)
                .font(.headline)
            Label(trip.destination, systemImage: "mappin.and.ellipse")
                .footnoteSecondary()
            HStack(spacing: Theme.Spacing.sm) {
                if let range = trip.dateRangeText {
                    Text(range)
                }
                if itemCount > 0 {
                    Text("·")
                    Text("\(itemCount) \(itemCount == 1 ? "plan" : "plans")")
                }
            }
            .captionSecondary()
        }
        .padding(.vertical, Theme.Spacing.xs)
    }
}
