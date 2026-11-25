import MapKit
import SwiftUI

struct TransportTravelTimeView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: TransportTravelTime
    let onUseEstimate: (TimeInterval) -> Void

    init(request: TravelTimeRequest, onUseEstimate: @escaping (TimeInterval) -> Void) {
        _model = StateObject(wrappedValue: TransportTravelTime(request: request))
        self.onUseEstimate = onUseEstimate
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Travel by", value: model.request.mode.label)
                    LabeledContent("Starts", value: model.request.departure.formatted(date: .abbreviated, time: .shortened))
                }

                if model.isLoading {
                    Section {
                        ProgressView("Finding places…")
                    }
                } else {
                    Section {
                        if !model.origins.isEmpty {
                            placePicker("From", places: model.origins, selection: $model.originIndex)
                        }
                        if !model.destinations.isEmpty {
                            placePicker("To", places: model.destinations, selection: $model.destinationIndex)
                        }
                    } header: {
                        Text("Confirm places")
                    } footer: {
                        Text("Check the matched addresses before calculating.")
                    }
                    Section {
                        Button {
                            Task { await model.calculate() }
                        } label: {
                            if model.isCalculating {
                                ProgressView("Calculating…")
                            } else {
                                Text("Get estimate")
                            }
                        }
                        .disabled(!model.canCalculate)
                    }
                }

                if let duration = model.duration, let arrival = model.arrival {
                    Section {
                        LabeledContent("Travel time", value: Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                        LabeledContent("Estimated arrival", value: arrival.formatted(date: .abbreviated, time: .shortened))
                        Button("Use estimate") {
                            onUseEstimate(duration)
                            dismiss()
                        }
                    } footer: {
                        Text("Estimate by Apple Maps. Actual travel times may vary. Using this estimate updates Ends.")
                    }
                }

                if let error = model.errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(Theme.Colors.textSecondary)
                        if model.origins.isEmpty || model.destinations.isEmpty {
                            Button("Retry finding places") {
                                Task { await model.loadPlaces() }
                            }
                            .disabled(model.isLoading)
                        }
                    }
                }
            }
            .navigationTitle("Travel time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task { await model.loadPlaces() }
        .onDisappear { model.cancel() }
    }

    private func placeLabel(_ place: MKMapItem) -> String {
        let name = place.name?.nilIfBlank
        let address = place.placemark.title?.nilIfBlank
        if let name, let address, name != address {
            return "\(name), \(address)"
        }
        return name ?? address ?? "Place"
    }

    private func placePicker(_ title: String, places: [MKMapItem], selection: Binding<Int>) -> some View {
        Picker(title, selection: selection) {
            ForEach(places.indices, id: \.self) { index in
                Text(placeLabel(places[index]))
                    .tag(index)
            }
        }
        .pickerStyle(.navigationLink)
    }
}
