import SwiftUI

/// What's happening today: the current or next trip and today's plans.
struct TodayView: View {
    @EnvironmentObject private var services: AppServices
    @State private var showNewTrip = false

    private var focusTrip: Trip? {
        services.trips.currentTrips.first ?? services.trips.upcomingTrips.first
    }

    private var todaysItems: [ItineraryItem] {
        services.itinerary.todaysItems()
    }

    var body: some View {
        Group {
            if services.trips.trips.isEmpty && !services.trips.isLoading {
                EmptyState(
                    systemImage: "sun.max",
                    title: "Where to next?",
                    message: "Plan a trip and Moss will show what's happening each day.",
                    actionTitle: "New trip",
                    action: { showNewTrip = true }
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                        if let trip = focusTrip {
                            NavigationLink(value: trip) {
                                focusCard(for: trip)
                            }
                            .buttonStyle(.plain)
                        }
                        todaySection
                    }
                    .padding(Theme.Spacing.lg)
                }
            }
        }
        .background(Theme.Colors.background)
        .navigationTitle("Today")
        .navigationDestination(for: Trip.self) { trip in
            TripDetailView(tripID: trip.id)
        }
        .refreshable { await services.refreshAll() }
        .sheet(isPresented: $showNewTrip) {
            TripEditorView()
        }
    }

    private func focusCard(for trip: Trip) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text(trip.isActive() ? "Happening now" : countdownText(for: trip))
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.Colors.accent)
                Text(trip.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.Colors.textPrimary)
                Label(trip.destination, systemImage: "mappin.and.ellipse")
                    .footnoteSecondary()
                if let range = trip.dateRangeText {
                    Label(range, systemImage: "calendar")
                        .footnoteSecondary()
                }
            }
        }
    }

    @ViewBuilder
    private var todaySection: some View {
        Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
            .font(.headline)
        if todaysItems.isEmpty {
            Card {
                Text("Nothing scheduled today.")
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        } else {
            Card {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    ForEach(todaysItems) { item in
                        ItineraryItemRow(item: item)
                        if item.id != todaysItems.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func countdownText(for trip: Trip) -> String {
        guard let startsAt = trip.startsAt else { return "Upcoming" }
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: Date()),
            to: calendar.startOfDay(for: startsAt)
        ).day ?? 0
        switch days {
        case ..<1: return "Upcoming"
        case 1: return "Tomorrow"
        default: return "In \(days) days"
        }
    }
}
