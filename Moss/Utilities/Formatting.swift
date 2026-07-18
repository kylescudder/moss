import Foundation

extension Trip {
    var dateRangeText: String? {
        guard let startsAt else { return nil }
        if let endsAt {
            return "\(startsAt.formatted(date: .abbreviated, time: .omitted)) - \(endsAt.formatted(date: .abbreviated, time: .omitted))"
        }
        return startsAt.formatted(date: .abbreviated, time: .omitted)
    }
}

extension ItineraryItem {
    var timeText: String? {
        guard let startsAt else { return nil }
        if let endsAt {
            return "\(startsAt.formatted(date: .omitted, time: .shortened)) - \(endsAt.formatted(date: .omitted, time: .shortened))"
        }
        return startsAt.formatted(date: .omitted, time: .shortened)
    }
}

