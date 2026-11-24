import SwiftUI

/// Who one trip is shared with. Owners invite and remove people; members see
/// who else is on the trip and can leave it.
struct TripSharingView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    let trip: Trip
    @State private var confirmLeave = false

    private var tripID: String { trip.id.uuidString.lowercased() }
    private var ownerID: String { trip.ownerID.uuidString.lowercased() }

    /// Membership of this trip itself, not through the owner's library.
    private var tripRole: ShareRole? {
        services.currentUserID.flatMap { services.tripSharing.role(in: tripID, userID: $0) }
    }

    private var libraryRole: ShareRole? {
        services.currentUserID.flatMap { services.librarySharing.role(in: ownerID, userID: $0) }
    }

    var body: some View {
        NavigationStack {
            Form {
                if services.isOwner(of: trip) {
                    Section {
                        Text("Invite people to plan \(trip.title) with you. They see this trip and its plans on their own devices.")
                            .footnoteSecondary()
                    }
                    ShareMembersSections(
                        sharing: services.tripSharing,
                        spaceID: tripID,
                        currentUserID: services.currentUserID
                    )
                    Section {
                        NavigationLink("Share all my trips") {
                            AllTripsSharingView()
                        }
                    } footer: {
                        Text("Share every trip you own, including future ones, instead of one at a time.")
                    }
                } else {
                    if let libraryRole {
                        Section("Shared with you") {
                            Label(
                                "\(services.ownerName(of: trip) ?? "The owner") shares all their trips with you as \(libraryRole.label.lowercased()).",
                                systemImage: "person.2"
                            )
                            .font(.callout)
                        }
                    }
                    if tripRole != nil {
                        ShareMembersSections(
                            sharing: services.tripSharing,
                            spaceID: tripID,
                            currentUserID: services.currentUserID
                        )
                        Section {
                            Button("Leave trip", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                                confirmLeave = true
                            }
                        } footer: {
                            if libraryRole != nil {
                                Text("You'll still see this trip while its owner shares all their trips with you.")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Sharing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Leave \(trip.title)?", isPresented: $confirmLeave) {
                Button("Leave", role: .destructive) {
                    Task {
                        await services.tripSharing.leave(spaceID: tripID)
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The trip disappears from your devices. Everyone else keeps it.")
            }
        }
    }
}
