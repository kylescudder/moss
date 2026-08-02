import SwiftUI

struct TripsListView: View {
    @EnvironmentObject private var services: AppServices
    @State private var showCreateTrip = false
    @State private var showPaywall = false
    @State private var creationCheckError: String?
    @State private var showVerificationPending = false
    @State private var showAuthenticationRequired = false

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
                        switch await services.canCreateTrip() {
                        case .available:
                            showCreateTrip = true
                        case .limitReached:
                            showPaywall = true
                        case .subscriptionVerificationPending:
                            showVerificationPending = true
                        case .authenticationRequired:
                            showAuthenticationRequired = true
                        case .unavailable(let message):
                            creationCheckError = message
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
        .alert("Subscription verification needed", isPresented: $showVerificationPending) {
            Button("Retry verification") {
                Task { await services.billing.retryEntitlementVerification() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Moss must confirm your Apple subscription before paid trip creation is available.")
        }
        .alert("Sign in again", isPresented: $showAuthenticationRequired) {
            Button("Refresh session") {
                Task { _ = await services.auth.refreshSession() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Moss couldn't verify your signed-in session.")
        }
        .alert("Couldn't check trip allowance", isPresented: Binding(
            get: { creationCheckError != nil },
            set: { if !$0 { creationCheckError = nil } }
        ), presenting: creationCheckError) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
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
