import Foundation

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Date {
    var iso8601: String {
        ISO8601DateFormatter.mossFractional.string(from: self)
    }
}

func parseISO8601Date(_ value: String?) -> Date? {
    guard let value, !value.isEmpty else { return nil }
    return ISO8601DateFormatter.mossFractional.date(from: value)
        ?? ISO8601DateFormatter.mossInternetDateTime.date(from: value)
        ?? ISO8601DateFormatter.mossFullDate.date(from: value)
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let mossInternetDateTime: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    nonisolated(unsafe) static let mossFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) static let mossFullDate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }()
}
