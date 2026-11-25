import Foundation

/// Moss's values for the shared sharing core (`SharingRepository`,
/// `ShareMembersSections`). People can share one trip, or every trip they own
/// (their library, whose space ID is their account ID). The endpoints are
/// `Backend/src/sharing.ts`.
enum SharingAppConfiguration {
    static let spaces: [SharingSpace] = [.trip, .library]
}

extension SharingSpace {
    static let trip = SharingSpace(
        name: "trips",
        membersTable: "trip_members",
        invitesTable: "trip_pending_invites",
        spaceColumn: "trip_id",
        invite: SharingEndpoint(path: "api/sharing/trip/invite", keys: ["space_id", "email", "role"]),
        removeMember: SharingEndpoint(path: "api/sharing/trip/remove_member", keys: ["space_id", "user_id"]),
        revokeInvite: SharingEndpoint(path: "api/sharing/trip/revoke_invite", keys: ["invite_id"]),
        memberProfiles: SharingEndpoint(path: "api/sharing/trip/member_profiles", keys: ["space_id"]),
        incoming: SharingEndpoint(path: "api/sharing/trip/incoming", keys: []),
        accept: SharingEndpoint(path: "api/sharing/trip/accept", keys: ["invite_id"]),
        decline: SharingEndpoint(path: "api/sharing/trip/decline", keys: ["invite_id"]),
        copy: SharingCopy(
            destination: "this trip",
            pendingFooter: "They join this trip once they accept the invite in Moss.",
            inviteFooter: "We'll email them an invite to accept in Moss. Editors can change the trip and add plans; viewers can only look."
        )
    )

    static let library = SharingSpace(
        name: "library",
        membersTable: "library_members",
        invitesTable: "library_pending_invites",
        spaceColumn: "library_id",
        invite: SharingEndpoint(path: "api/sharing/library/invite", keys: ["space_id", "email", "role"]),
        removeMember: SharingEndpoint(path: "api/sharing/library/remove_member", keys: ["space_id", "user_id"]),
        revokeInvite: SharingEndpoint(path: "api/sharing/library/revoke_invite", keys: ["invite_id"]),
        memberProfiles: SharingEndpoint(path: "api/sharing/library/member_profiles", keys: ["space_id"]),
        incoming: SharingEndpoint(path: "api/sharing/library/incoming", keys: []),
        accept: SharingEndpoint(path: "api/sharing/library/accept", keys: ["invite_id"]),
        decline: SharingEndpoint(path: "api/sharing/library/decline", keys: ["invite_id"]),
        copy: SharingCopy(
            destination: "all your trips",
            pendingFooter: "They see all your trips once they accept the invite in Moss.",
            inviteFooter: "We'll email them an invite to accept in Moss. They'll see every trip you own, including trips you plan later. Editors can change them and add plans; viewers can only look. Only you can delete your trips."
        )
    )
}
