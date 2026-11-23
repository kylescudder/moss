import SwiftUI
import WidgetKit

private let mossGreen = Color(red: 0.02, green: 0.42, blue: 0.36)

private struct NextTripEntry: TimelineEntry {
    let date: Date
    let snapshot: NextTripSnapshot?
}

private struct NextTripProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextTripEntry {
        let calendar = Calendar.current
        return NextTripEntry(
            date: Date(),
            snapshot: NextTripSnapshot(
                trips: [WidgetTrip(
                    title: "Lisbon long weekend",
                    destination: "Lisbon, Portugal",
                    startsAt: calendar.date(byAdding: .day, value: 6, to: Date()),
                    endsAt: calendar.date(byAdding: .day, value: 9, to: Date())
                )],
                items: [],
                updatedAt: Date()
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (NextTripEntry) -> Void) {
        completion(NextTripEntry(date: Date(), snapshot: WidgetSnapshotStore.nextTrip()))
    }

    /// One entry now and one at each of the next seven midnights. Every entry
    /// derives its trip and "today" from the dated snapshot, so the widget
    /// moves on to the next day (and the next trip) while the app is closed.
    func getTimeline(in context: Context, completion: @escaping (Timeline<NextTripEntry>) -> Void) {
        let calendar = Calendar.current
        let snapshot = WidgetSnapshotStore.nextTrip()
        let today = calendar.startOfDay(for: Date())
        let midnights = (1...7).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        let entries = [NextTripEntry(date: Date(), snapshot: snapshot)]
            + midnights.map { NextTripEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

private struct NextTripWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NextTripEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot, snapshot.covers(entry.date),
               let trip = snapshot.focusTrip(on: entry.date) {
                HStack(alignment: .top, spacing: 16) {
                    tripSummary(trip)
                    if family == .systemMedium {
                        todayList(snapshot.items(on: entry.date))
                    }
                }
            } else {
                placeholder(stale: entry.snapshot.map { !$0.covers(entry.date) } ?? false)
            }
        }
        .widgetURL(URL(string: "moss://shortcut/today"))
        .containerBackground(for: .widget) {
            Color(.systemBackground)
        }
    }

    private func placeholder(stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "suitcase")
                .font(.title2)
                .foregroundStyle(mossGreen)
            Spacer()
            Text(stale ? "Open Moss" : "Where to next?")
                .font(.headline)
            Text(stale ? "to refresh your trips." : "Plan a trip in Moss.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func tripSummary(_ trip: WidgetTrip) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(statusText(trip).uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(mossGreen)
            Text(trip.title)
                .font(.headline)
                .lineLimit(2)
            Text(trip.destination)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let startsAt = trip.startsAt {
                Text(startsAt, format: .dateTime.day().month(.abbreviated))
                    .font(.caption.weight(.medium))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func todayList(_ items: [WidgetItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TODAY")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if items.isEmpty {
                Text("Nothing scheduled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items.prefix(3), id: \.self) { item in
                    Label {
                        Text(item.title).lineLimit(1)
                    } icon: {
                        Image(systemName: item.symbol).foregroundStyle(mossGreen)
                    }
                    .font(.caption)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func statusText(_ trip: WidgetTrip) -> String {
        if trip.isActive(on: entry.date) { return "Happening now" }
        guard let startsAt = trip.startsAt else { return "Upcoming" }
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: entry.date),
            to: calendar.startOfDay(for: startsAt)
        ).day ?? 0
        switch days {
        case ..<1: return "Upcoming"
        case 1: return "Tomorrow"
        default: return "In \(days) days"
        }
    }
}

struct MossNextTripWidget: Widget {
    let kind = WidgetSnapshotStore.nextTripWidgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NextTripProvider()) { entry in
            NextTripWidgetView(entry: entry)
        }
        .configurationDisplayName("Next Trip")
        .description("Your current or next trip, and today's plans.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct MossWidgetsBundle: WidgetBundle {
    var body: some Widget {
        MossNextTripWidget()
    }
}
