import Combine
import Foundation
import MapKit

extension TransportMode {
    var mapKitType: MKDirectionsTransportType {
        switch self {
        case .transit: .transit
        case .driving: .automobile
        case .walking: .walking
        case .cycling: .cycling
        }
    }
}

/// The only network boundary for place matching and Apple Maps travel times.
@MainActor
protocol TravelTimeProviding {
    func places(matching query: String) async throws -> [MKMapItem]
    func duration(from: MKMapItem, to: MKMapItem, request: TravelTimeRequest) async throws -> TimeInterval
}

@MainActor
struct AppleMapsTravelTime: TravelTimeProviding {
    func places(matching query: String) async throws -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]
        let response = try await MKLocalSearch(request: request).start()
        try Task.checkCancellation()
        return Array(response.mapItems.prefix(10))
    }

    func duration(from: MKMapItem, to: MKMapItem, request: TravelTimeRequest) async throws -> TimeInterval {
        let directionsRequest = MKDirections.Request()
        directionsRequest.source = from
        directionsRequest.destination = to
        directionsRequest.transportType = request.mode.mapKitType
        directionsRequest.departureDate = request.departure
        let response = try await MKDirections(request: directionsRequest).calculateETA()
        try Task.checkCancellation()
        return response.expectedTravelTime
    }
}

@MainActor
final class TransportTravelTime: ObservableObject {
    let request: TravelTimeRequest
    @Published private(set) var origins: [MKMapItem] = []
    @Published private(set) var destinations: [MKMapItem] = []
    @Published var originIndex = 0 { didSet { invalidateEstimate() } }
    @Published var destinationIndex = 0 { didSet { invalidateEstimate() } }
    @Published private(set) var duration: TimeInterval?
    @Published private(set) var isLoading = false
    @Published private(set) var isCalculating = false
    @Published private(set) var errorMessage: String?
    private let provider: any TravelTimeProviding
    private var generation = 0

    init(request: TravelTimeRequest, provider: any TravelTimeProviding = AppleMapsTravelTime()) {
        self.request = request
        self.provider = provider
    }

    var canCalculate: Bool {
        origins.indices.contains(originIndex) && destinations.indices.contains(destinationIndex)
            && !isLoading && !isCalculating
    }

    var arrival: Date? {
        duration.map { request.departure.addingTimeInterval($0) }
    }

    func loadPlaces() async {
        generation += 1
        let current = generation
        isLoading = true
        duration = nil
        errorMessage = nil
        defer { if current == generation { isLoading = false } }
        do {
            // Sequential searches avoid sending bursts to MapKit.
            let from = try await provider.places(matching: request.from)
            let to = try await provider.places(matching: request.to)
            guard current == generation, !Task.isCancelled else { return }
            origins = from
            destinations = to
            if from.isEmpty || to.isEmpty {
                errorMessage = "Apple Maps couldn't find both places. Go back and enter a more specific name or address."
            }
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            errorMessage = "Apple Maps couldn't find these places. Check your connection and try again, or set Ends yourself."
        }
    }

    func calculate() async {
        guard canCalculate else { return }
        generation += 1
        let current = generation
        isCalculating = true
        duration = nil
        errorMessage = nil
        defer { if current == generation { isCalculating = false } }
        do {
            let seconds = try await provider.duration(
                from: origins[originIndex], to: destinations[destinationIndex], request: request
            )
            guard current == generation, !Task.isCancelled else { return }
            guard seconds.isFinite, seconds > 0, seconds < 365 * 24 * 60 * 60 else {
                errorMessage = "Apple Maps didn't return a usable travel time. Set Ends yourself."
                return
            }
            // Date pickers use minutes; round up so arrival is never earlier than the estimate.
            duration = ceil(seconds / 60) * 60
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            errorMessage = "No estimate is available for this mode and departure time. Try again or set Ends yourself."
        }
    }

    func invalidateEstimate() {
        generation += 1
        duration = nil
        errorMessage = nil
        isCalculating = false
    }

    func cancel() {
        invalidateEstimate()
        isLoading = false
    }
}
