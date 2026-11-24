import SwiftUI

/// Sharing every trip the account owns, and the trips other people share with it.
struct AllTripsSharingView: View {
    @EnvironmentObject private var services: AppServices
    @State private var libraryToLeave: ShareMember?
    @State private var tripToLeave: Trip?

    /// Other people's libraries this account belongs to.
    private var sharedLibraries: [ShareMember] {
        guard let userID = services.currentUserID else { return [] }
        return services.librarySharing.memberships(of: userID).filter { $0.role != .owner }
    }

    /// Single trips other people share with this account.
    private var sharedTrips: [(Trip, ShareRole)] {
        guard let userID = services.currentUserID else { return [] }
        let roles = Dictionary(
            services.tripSharing.memberships(of: userID)
                .filter { $0.role != .owner }
                .map { ($0.spaceID, $0.role) },
            uniquingKeysWith: { first, _ in first }
        )
        return services.trips.trips.compactMap { trip in
            roles[trip.id.uuidString.lowercased()].map { (trip, $0) }
        }
    }

    var body: some View {
        Form {
            if let userID = services.currentUserID {
                Section {
                    Text("People you add here see every trip you own, including trips you plan later. To share just one trip, open it and tap Share.")
                        .footnoteSecondary()
                }
                ShareMembersSections(
                    sharing: services.librarySharing,
                    spaceID: userID,
                    currentUserID: userID
                )
            }

            if !sharedLibraries.isEmpty || !sharedTrips.isEmpty {
                Section {
                    ForEach(sharedLibraries) { library in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("All of \(services.librarySharing.displayName(for: library.spaceID) ?? "someone")'s trips")
                                    .font(.callout)
                                Text(library.role.label)
                                    .captionSecondary()
                            }
                            Spacer()
                            Button("Leave", role: .destructive) { libraryToLeave = library }
                                .buttonStyle(.borderless)
                        }
                    }
                    ForEach(sharedTrips, id: \.0.id) { trip, role in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(trip.title)
                                    .font(.callout)
                                Text(role.label)
                                    .captionSecondary()
                            }
                            Spacer()
                            Button("Leave", role: .destructive) { tripToLeave = trip }
                                .buttonStyle(.borderless)
                        }
                    }
                } header: {
                    Text("Shared with you")
                }
            }
        }
        .navigationTitle("Share all trips")
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            "Stop seeing these trips?",
            isPresented: Binding(get: { libraryToLeave != nil }, set: { if !$0 { libraryToLeave = nil } }),
            presenting: libraryToLeave
        ) { library in
            Button("Leave", role: .destructive) {
                Task { await services.librarySharing.leave(spaceID: library.spaceID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Their trips disappear from your devices, except any they've shared with you one by one.")
        }
        .alert(
            "Leave \(tripToLeave?.title ?? "this trip")?",
            isPresented: Binding(get: { tripToLeave != nil }, set: { if !$0 { tripToLeave = nil } }),
            presenting: tripToLeave
        ) { trip in
            Button("Leave", role: .destructive) {
                Task { await services.tripSharing.leave(spaceID: trip.id.uuidString.lowercased()) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The trip disappears from your devices. Everyone else keeps it.")
        }
    }
}
