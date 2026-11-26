import MapKit
import SwiftUI

struct TripMapScreen: View {
    @EnvironmentObject private var services: AppServices
    let trip: Trip

    var body: some View {
        TripMapView(
            trip: trip,
            items: services.itinerary.items(for: trip.id),
            canEdit: services.canEdit(trip)
        ) { visited, item in
            guard services.canEdit(trip) else { return false }
            return await services.itinerary.setVisited(visited, for: item)
        }
    }
}

struct TripMapView: View {
    let trip: Trip
    let items: [ItineraryItem]
    let canEdit: Bool
    let setVisited: (Bool, ItineraryItem) async -> Bool
    @StateObject private var locations = TripMapPlaces()
    @StateObject private var routes = TripMapRoutes()
    @State private var routeRetry = 0
    @State private var position: MapCameraPosition = .automatic
    @State private var selection: String?
    @State private var saving: Set<UUID> = []
    @State private var saveFailed = false
    @State private var retry = 0
    @State private var showsTravelLines = true

    private var places: [TripMapPlace] { TripMapPlace.places(for: items) }
    private var routeInputs: [TripMapRouteInput] {
        guard showsTravelLines, !locations.isLoading else { return [] }
        return TripMapRouteInput.inputs(for: items, coordinates: locations.coordinates)
    }
    private var locatedItems: [ItineraryItem] {
        let ids = Set(places.map(\.itemID))
        return items.filter { ids.contains($0.id) }
    }
    private var selectedItem: ItineraryItem? {
        guard let place = places.first(where: { $0.id == selection }) else { return nil }
        return items.first { $0.id == place.itemID }
    }

    var body: some View {
        List {
            if places.isEmpty {
                Section {
                    EmptyState(systemImage: "map", title: "No places yet",
                               message: "Add a location to a plan to see it on your trip map.")
                }
            } else {
                Section {
                    Map(position: $position, selection: $selection) {
                        if showsTravelLines {
                            ForEach(routeInputs) { input in
                                if let polyline = routes.polylines[input.id] {
                                    MapPolyline(polyline)
                                        .stroke(Theme.Colors.accent, lineWidth: 4)
                                }
                            }
                        }
                        ForEach(places) { place in
                            if let coordinate = locations.coordinates[place.id],
                               let item = items.first(where: { $0.id == place.itemID }) {
                                Marker("\(item.title) · \(place.location)",
                                       systemImage: item.visitedAt != nil ? "checkmark" : item.kind.symbol,
                                       coordinate: coordinate)
                                    .tint(item.visitedAt != nil ? Theme.Colors.accent : .gray)
                                    .tag(place.id)
                            }
                        }
                    }
                    .mapControls { MapCompass(); MapScaleView() }
                    .frame(height: 300)
                    .listRowInsets(EdgeInsets())
                    .accessibilityLabel("Places on \(trip.title)")
                    Button("Show all pins", systemImage: "arrow.up.left.and.arrow.down.right") {
                        position = .automatic
                        selection = nil
                    }
                    Toggle("Transport routes", isOn: $showsTravelLines)
                    if showsTravelLines {
                        Text("Apple Maps routes use each transport plan's travel mode. Routes may be unavailable for some modes or places.")
                            .font(.caption)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                    Text("\(locatedItems.filter { $0.visitedAt != nil }.count) of \(locatedItems.count) plans visited")
                        .font(.headline)
                    Text("Visit progress is shared with everyone on this trip. Marking a transport plan updates both endpoints.")
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                    if routes.isLoading {
                        ProgressView("Finding transport routes…")
                    }
                    if !routes.unavailable.isEmpty {
                        Text("Some transport routes aren't available in this map. Open the plan's route in Apple Maps for more options.")
                            .font(.footnote)
                        Button("Retry transport routes") { routeRetry += 1 }
                    }
                    if locations.isLoading {
                        ProgressView("Finding places…")
                    }
                    if !locations.unavailable.isEmpty {
                        Text("\(locations.unavailable.count) places couldn't be found. Check their location text or try again when online.")
                            .font(.footnote)
                        Button("Retry place search") { retry += 1 }
                    }
                }
                if let selectedItem {
                    Section("Selected plan") { planRow(selectedItem) }
                }
                Section("Places") {
                    ForEach(locatedItems) { item in planRow(item) }
                }
                let missing = items.count - locatedItems.count
                if missing > 0 {
                    Section {
                        Text("\(missing) plans have no location and aren't shown on the map.")
                            .font(.footnote)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                }
            }
        }
        .navigationTitle("Trip map")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: SearchKey(places: places, destination: trip.destination, retry: retry)) {
            await locations.load(places, destination: trip.destination)
        }
        .task(id: RouteKey(inputs: routeInputs, retry: routeRetry)) {
            await routes.load(routeInputs)
        }
        .alert("Visit not saved", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Moss couldn't save your visit. Please try again.")
        }
    }

    private func planRow(_ item: ItineraryItem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ItineraryItemRow(item: item, showsDate: true)
            ForEach(places.filter { $0.itemID == item.id }) { place in
                if locations.unavailable.contains(place.id) {
                    Label("Not on map: \(place.location)", systemImage: "mappin.slash")
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                } else if let coordinate = locations.coordinates[place.id] {
                    Button("Show \(place.location) on map") {
                        selection = place.id
                        position = .region(MKCoordinateRegion(
                            center: coordinate,
                            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                        ))
                    }
                    .font(.caption)
                }
            }
            if item.kind == .transport {
                if let mode = item.transportMode,
                   let from = item.locationName?.nilIfBlank, let to = item.destinationName?.nilIfBlank {
                    if showsTravelLines, routes.unavailable.contains(item.id) {
                        Label("Route unavailable for \(mode.label.lowercased())", systemImage: "exclamationmark.circle")
                            .font(.caption)
                    }
                    Button("Open route in Apple Maps", systemImage: "arrow.triangle.turn.up.right.diamond") {
                        guard let fromCoordinate = locations.coordinates["\(item.id):from"],
                              let toCoordinate = locations.coordinates["\(item.id):to"] else { return }
                        let source = MKMapItem(placemark: MKPlacemark(coordinate: fromCoordinate))
                        let destination = MKMapItem(placemark: MKPlacemark(coordinate: toCoordinate))
                        source.name = from
                        destination.name = to
                        MKMapItem.openMaps(with: [source, destination], launchOptions: [MKLaunchOptionsDirectionsModeKey: mode.mapsDirectionsMode])
                    }
                    .disabled(locations.coordinates["\(item.id):from"] == nil || locations.coordinates["\(item.id):to"] == nil)
                } else {
                    Text("Add From, To and a travel mode to this plan to show its route.")
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            if canEdit {
                Button(item.visitedAt == nil ? "Mark as visited" : "Mark as unvisited",
                       systemImage: item.visitedAt == nil ? "checkmark.circle" : "arrow.uturn.backward") {
                    guard saving.insert(item.id).inserted else { return }
                    Task {
                        let saved = await setVisited(item.visitedAt == nil, item)
                        saving.remove(item.id)
                        if !saved { saveFailed = true }
                    }
                }
                .disabled(saving.contains(item.id))
                .accessibilityLabel("\(item.visitedAt == nil ? "Mark as visited" : "Mark as unvisited"): \(item.title)")
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, Theme.Spacing.xs)
    }

    private struct RouteKey: Equatable {
        let inputs: [TripMapRouteInput]
        let retry: Int
    }

    private struct SearchKey: Equatable {
        let places: [TripMapPlace]
        let destination: String
        let retry: Int
    }
}
