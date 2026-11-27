import MapKit
import SwiftUI

struct TripMapRouteInput: Equatable, Identifiable {
    let id: UUID
    let fromLatitude: Double
    let fromLongitude: Double
    let toLatitude: Double
    let toLongitude: Double
    let mode: TransportMode
    let departure: Date?

    static func inputs(for items: [ItineraryItem], coordinates: [String: CLLocationCoordinate2D]) -> [Self] {
        items.compactMap { item in
            guard item.kind == .transport, let mode = item.transportMode,
                  let from = coordinates["\(item.id):from"],
                  let to = coordinates["\(item.id):to"] else { return nil }
            return Self(id: item.id, fromLatitude: from.latitude, fromLongitude: from.longitude,
                        toLatitude: to.latitude, toLongitude: to.longitude, mode: mode, departure: item.startsAt)
        }
    }
}

@MainActor
protocol TripMapRouting {
    func route(for input: TripMapRouteInput) async throws -> MKPolyline?
}

@MainActor
struct AppleMapsTripRouting: TripMapRouting {
    static func request(for input: TripMapRouteInput) -> MKDirections.Request {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: input.fromLatitude, longitude: input.fromLongitude)))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: input.toLatitude, longitude: input.toLongitude)))
        request.transportType = input.mode.mapKitType
        request.departureDate = input.departure
        request.requestsAlternateRoutes = false
        return request
    }

    func route(for input: TripMapRouteInput) async throws -> MKPolyline? {
        let directions = MKDirections(request: Self.request(for: input))
        return try await withTaskCancellationHandler {
            let response = try await directions.calculate()
            try Task.checkCancellation()
            return response.routes.first?.polyline
        } onCancel: {
            // MKDirections is confined to the main actor, including cancellation.
            Task { @MainActor in directions.cancel() }
        }
    }
}

@MainActor
final class TripMapRoutes: ObservableObject {
    @Published private(set) var polylines: [UUID: MKPolyline] = [:]
    @Published private(set) var unavailable: Set<UUID> = []
    @Published private(set) var isLoading = false
    private var cache: [UUID: (TripMapRouteInput, MKPolyline)] = [:]
    private var generation = UUID()
    private let provider: any TripMapRouting

    init(provider: any TripMapRouting = AppleMapsTripRouting()) { self.provider = provider }

    func load(_ inputs: [TripMapRouteInput]) async {
        let token = UUID()
        generation = token
        polylines = [:]
        unavailable = []
        isLoading = !inputs.isEmpty
        defer { if generation == token { isLoading = false } }
        // Serial requests avoid bursts, and toggling visibility reuses successful routes.
        for input in inputs {
            guard !Task.isCancelled, generation == token else { return }
            if let (cachedInput, polyline) = cache[input.id], cachedInput == input {
                polylines[input.id] = polyline
                continue
            }
            do {
                let polyline = try await provider.route(for: input)
                guard !Task.isCancelled, generation == token else { return }
                if let polyline, polyline.pointCount > 1 {
                    polylines[input.id] = polyline
                    cache[input.id] = (input, polyline)
                } else {
                    unavailable.insert(input.id)
                }
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                unavailable.insert(input.id)
                Log.error(error, category: "trip-map.route")
            }
        }
    }
}

extension TransportMode {
    var mapsDirectionsMode: String {
        switch self {
        case .transit: MKLaunchOptionsDirectionsModeTransit
        case .driving: MKLaunchOptionsDirectionsModeDriving
        case .walking: MKLaunchOptionsDirectionsModeWalking
        case .cycling: MKLaunchOptionsDirectionsModeCycling
        }
    }
}
