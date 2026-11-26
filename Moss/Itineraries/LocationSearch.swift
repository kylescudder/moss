import MapKit
import SwiftUI

struct LocationSuggestion: Equatable, Sendable {
    let title: String
    let subtitle: String
}

/// Each query owns its completer so a late callback cannot replace newer results.
@MainActor
final class LocationSearch: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published private(set) var results: [LocationSuggestion] = []
    @Published private(set) var isSearching = false
    @Published private(set) var message: String?
    private(set) var completer: MKLocalSearchCompleter?

    func search(_ query: String) {
        cancel()
        guard let query = query.nilIfBlank else { return }
        let completer = MKLocalSearchCompleter()
        completer.resultTypes = [.address, .pointOfInterest]
        completer.delegate = self
        self.completer = completer
        isSearching = true
        completer.queryFragment = query
    }

    func cancel() {
        completer?.delegate = nil
        completer?.cancel()
        completer = nil
        results = []
        message = nil
        isSearching = false
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let source = ObjectIdentifier(completer)
        let suggestions = completer.results.map { LocationSuggestion(title: $0.title, subtitle: $0.subtitle) }
        Task { @MainActor [weak self] in
            self?.receive(suggestions, from: source)
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        let source = ObjectIdentifier(completer)
        Task { @MainActor [weak self] in
            self?.receiveFailure(error, from: source)
        }
    }

    func receive(_ suggestions: [LocationSuggestion], from source: ObjectIdentifier) {
        guard let completer, source == ObjectIdentifier(completer) else { return }
        results = suggestions
        isSearching = false
        message = results.isEmpty ? "No places found. Try adding a city, or keep your own text." : nil
    }

    func receiveFailure(_ error: Error, from source: ObjectIdentifier) {
        guard let completer, source == ObjectIdentifier(completer) else { return }
        results = []
        isSearching = false
        message = "Place search is unavailable. You can still enter a location yourself."
        Log.error(error, category: "place-search")
    }

    static func locationText(title: String, subtitle: String) -> String {
        [title.nilIfBlank, subtitle.nilIfBlank]
            .compactMap { $0 }
            .reduce(into: [String]()) { parts, part in
                if !parts.contains(part) { parts.append(part) }
            }
            .joined(separator: ", ")
    }
}

struct LocationSearchField: View {
    let title: String
    @Binding var text: String
    @StateObject private var search = LocationSearch()
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(title, text: $text)
            .focused($isFocused)
            .autocorrectionDisabled()
            .onChange(of: text) { _, query in
                if isFocused { search.search(query) }
            }
            .onChange(of: isFocused) { _, focused in
                if focused { search.search(text) } else { search.cancel() }
            }
            .onDisappear { search.cancel() }

        if isFocused {
            if search.isSearching {
                ProgressView("Searching Apple Maps…")
            }
            ForEach(Array(search.results.prefix(5).enumerated()), id: \.offset) { _, result in
                Button {
                    isFocused = false
                    search.cancel()
                    text = LocationSearch.locationText(title: result.title, subtitle: result.subtitle)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.title)
                            .foregroundStyle(Theme.Colors.textPrimary)
                        if !result.subtitle.isEmpty {
                            Text(result.subtitle)
                                .font(.caption)
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if let message = search.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.textSecondary)
            } else if !search.results.isEmpty {
                Text("Places from Apple Maps")
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
    }
}
