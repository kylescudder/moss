import SwiftUI

struct TripsListView: View {
    @EnvironmentObject private var services: AppServices
    @State private var showCreateTrip = false
    @State private var showPaywall = false

    var body: some View {
        List {
            if services.trips.isLoading && services.trips.trips.isEmpty {
                ProgressView()
            } else if services.trips.trips.isEmpty {
                EmptyState(
                    title: "No Trips",
                    message: "Create your first trip to start building a day-by-day itinerary.",
                    systemImage: "suitcase"
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(services.trips.trips) { trip in
                    NavigationLink {
                        TripDetailView(trip: trip)
                    } label: {
                        TripRowView(trip: trip)
                    }
                }
                .onDelete { offsets in
                    Task {
                        let trips = services.trips.trips
                        for index in offsets {
                            await services.trips.softDelete(trips[index])
                        }
                    }
                }
            }
        }
        .navigationTitle("Trips")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        if await services.canCreateTrip() {
                            showCreateTrip = true
                        } else {
                            showPaywall = true
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create trip")
            }
        }
        .refreshable {
            await services.trips.refresh()
        }
        .task {
            await services.trips.refresh()
        }
        .sheet(isPresented: $showCreateTrip) {
            TripEditorView()
        }
        .sheet(isPresented: $showPaywall) {
            SubscriptionPaywallView()
        }
    }
}

private struct TripRowView: View {
    let trip: Trip

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(trip.title)
                .font(.headline)
            Text(trip.destination)
                .foregroundStyle(Theme.Colors.textSecondary)
            if let range = trip.dateRangeText {
                Text(range)
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }
}

