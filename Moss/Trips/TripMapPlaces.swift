import MapKit
import SwiftUI

/// Endpoints have separate pins, but visit progress belongs to the plan.
struct TripMapPlace: Identifiable, Equatable, Sendable {
    let id: String
    let itemID: UUID
    let location: String

    static func places(for items: [ItineraryItem]) -> [Self] {
        items.flatMap { item in
            var places: [Self] = []
            if let location = item.locationName?.nilIfBlank {
                places.append(Self(id: "\(item.id):from", itemID: item.id, location: location))
            }
            if item.kind == .transport, let destination = item.destinationName?.nilIfBlank,
               destination != item.locationName?.nilIfBlank {
                places.append(Self(id: "\(item.id):to", itemID: item.id, location: destination))
            }
            return places
        }
    }
}

/// Dashed connections communicate itinerary order, not navigable routes.
struct TripMapLeg: Identifiable {
    let id: String
    let coordinates: [CLLocationCoordinate2D]

    static func legs(for places: [TripMapPlace], coordinates: [String: CLLocationCoordinate2D]) -> [Self] {
        zip(places, places.dropFirst()).compactMap { from, to in
            guard let start = coordinates[from.id], let end = coordinates[to.id],
                  start.latitude != end.latitude || start.longitude != end.longitude else { return nil }
            return Self(id: "\(from.id)→\(to.id)", coordinates: [start, end])
        }
    }
}

@MainActor
final class TripMapPlaces: ObservableObject {
    @Published private(set) var coordinates: [String: CLLocationCoordinate2D] = [:]
    @Published private(set) var unavailable: Set<String> = []
    @Published private(set) var isLoading = false
    private var generation = UUID()
    private var cache: [String: CLLocationCoordinate2D] = [:]
    private var regions: [String: MKCoordinateRegion] = [:]

    typealias Resolver = @MainActor (String, String) async throws -> CLLocationCoordinate2D?

    private func resolve(_ location: String, destination: String) async throws -> CLLocationCoordinate2D? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = location
        // Bias short place names toward the trip, without altering full addresses.
        if let region = regions[destination] {
            request.region = region
        } else {
            let regionRequest = MKLocalSearch.Request()
            regionRequest.naturalLanguageQuery = destination
            let regionSearch = MKLocalSearch(request: regionRequest)
            if let regionResponse = try? await regionSearch.start() {
                regions[destination] = regionResponse.boundingRegion
                request.region = regionResponse.boundingRegion
            }
        }
        try Task.checkCancellation()
        let search = MKLocalSearch(request: request)
        let response = try await search.start()
        try Task.checkCancellation()
        return response.mapItems.first?.placemark.coordinate
    }

    func load(_ places: [TripMapPlace], destination: String, resolver: Resolver? = nil) async {
        let token = UUID()
        generation = token
        coordinates = [:]
        unavailable = []
        isLoading = !places.isEmpty
        defer { if generation == token { isLoading = false } }
        for place in places {
            guard !Task.isCancelled, generation == token else { return }
            let key = "\(destination)\n\(place.location)"
            if let cached = cache[key] {
                coordinates[place.id] = cached
                continue
            }
            do {
                let coordinate: CLLocationCoordinate2D?
                if let resolver {
                    coordinate = try await resolver(place.location, destination)
                } else {
                    coordinate = try await resolve(place.location, destination: destination)
                }
                guard !Task.isCancelled, generation == token else { return }
                if let coordinate, CLLocationCoordinate2DIsValid(coordinate) {
                    cache[key] = coordinate
                    coordinates[place.id] = coordinate
                } else {
                    unavailable.insert(place.id)
                }
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                unavailable.insert(place.id)
                Log.error(error, category: "trip-map.search")
            }
        }
    }
}
