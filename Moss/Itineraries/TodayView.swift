import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var services: AppServices

    private var todaysItems: [ItineraryItem] {
        let calendar = Calendar.current
        return services.trips.trips.flatMap { trip in
            services.itinerary.items(for: trip)
        }
        .filter { item in
            guard let startsAt = item.startsAt else { return false }
            return calendar.isDateInToday(startsAt)
        }
        .sorted { ($0.startsAt ?? .distantFuture) < ($1.startsAt ?? .distantFuture) }
    }

    var body: some View {
        List {
            if todaysItems.isEmpty {
                EmptyState(
                    title: "Nothing Today",
                    message: "Items scheduled for today will show up here.",
                    systemImage: "sun.max"
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(todaysItems) { item in
                    ItineraryItemRow(item: item)
                }
            }
        }
        .navigationTitle("Today")
        .task {
            await services.trips.refresh()
            for trip in services.trips.trips {
                await services.itinerary.refresh(tripID: trip.id)
            }
        }
    }
}

