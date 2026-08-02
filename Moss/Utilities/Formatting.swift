import Foundation

extension Date {
    var iso8601: String { ISO8601DateFormatter.mossFractional.string(from: self) }
}

func parseISO8601Date(_ value: String?) -> Date? {
    guard let value, !value.isEmpty else { return nil }
    return ISO8601DateFormatter.mossFractional.date(from: value)
        ?? ISO8601DateFormatter.mossStandard.date(from: value)
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let mossFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) static let mossStandard = ISO8601DateFormatter()
}

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
