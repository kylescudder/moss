import SwiftUI
import WidgetKit

private let mossGreen = Color(red: 0.02, green: 0.42, blue: 0.36)

private struct NextTripEntry: TimelineEntry {
    let date: Date
    let snapshot: NextTripSnapshot?
}

private struct NextTripProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextTripEntry {
        NextTripEntry(
            date: Date(),
            snapshot: NextTripSnapshot(
                title: "Lisbon long weekend",
                destination: "Lisbon, Portugal",
                startsAt: Calendar.current.date(byAdding: .day, value: 6, to: Date()),
                endsAt: Calendar.current.date(byAdding: .day, value: 9, to: Date()),
                todaysItems: [],
                upcomingTripCount: 2,
                updatedAt: Date()
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (NextTripEntry) -> Void) {
        completion(NextTripEntry(date: Date(), snapshot: WidgetSnapshotStore.nextTrip()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextTripEntry>) -> Void) {
        // Refresh at midnight so the countdown and "today" stay correct.
        let midnight = Calendar.current.startOfDay(for: Date()).addingTimeInterval(24 * 60 * 60)
        completion(Timeline(
            entries: [NextTripEntry(date: Date(), snapshot: WidgetSnapshotStore.nextTrip())],
            policy: .after(midnight)
        ))
    }
}

private struct NextTripWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NextTripEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot, let title = snapshot.title {
                HStack(alignment: .top, spacing: 16) {
                    tripSummary(snapshot, title: title)
                    if family == .systemMedium {
                        todayList(snapshot)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "suitcase")
                        .font(.title2)
                        .foregroundStyle(mossGreen)
                    Spacer()
                    Text("Where to next?")
                        .font(.headline)
                    Text("Plan a trip in Moss.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .widgetURL(URL(string: "moss://shortcut/today"))
        .containerBackground(for: .widget) {
            Color(.systemBackground)
        }
    }

    private func tripSummary(_ snapshot: NextTripSnapshot, title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(statusText(snapshot).uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(mossGreen)
            Text(title)
                .font(.headline)
                .lineLimit(2)
            if let destination = snapshot.destination {
                Text(destination)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let startsAt = snapshot.startsAt {
                Text(startsAt, format: .dateTime.day().month(.abbreviated))
                    .font(.caption.weight(.medium))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func todayList(_ snapshot: NextTripSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TODAY")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if snapshot.todaysItems.isEmpty {
                Text("Nothing scheduled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.todaysItems, id: \.self) { item in
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

    private func statusText(_ snapshot: NextTripSnapshot) -> String {
        guard let startsAt = snapshot.startsAt else { return "Upcoming" }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: entry.date)
        let start = calendar.startOfDay(for: startsAt)
        let end = calendar.startOfDay(for: snapshot.endsAt ?? startsAt)
        if start <= today && today <= end { return "Happening now" }
        let days = calendar.dateComponents([.day], from: today, to: start).day ?? 0
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
