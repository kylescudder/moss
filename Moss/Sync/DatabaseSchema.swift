import Foundation
import PowerSync

/// Local SQLite schema for data that must remain available without a network.
/// PowerSync adds each table's `id` column automatically.
enum DatabaseSchema {
    static let profiles = Table(
        name: "profiles",
        columns: [
            .text("username"),
            .text("display_name"),
            .integer("is_premium_account"),
            .text("created_at"),
            .text("updated_at"),
            .text("deleted_at"),
        ]
    )

    static let trips = Table(
        name: "trips",
        columns: [
            .text("owner_id"),
            .text("title"),
            .text("destination"),
            .text("starts_at"),
            .text("ends_at"),
            .text("notes"),
            .text("created_at"),
            .text("updated_at"),
            .text("deleted_at"),
        ],
        indexes: [
            Index(
                name: "trips_owner_starts",
                columns: [
                    IndexedColumn.ascending("owner_id"),
                    IndexedColumn.ascending("starts_at"),
                ]
            ),
        ]
    )

    static let itineraryItems = Table(
        name: "itinerary_items",
        columns: [
            .text("owner_id"),
            .text("trip_id"),
            .text("kind"),
            .text("title"),
            .text("location_name"),
            .text("destination_name"),
            .text("transport_mode"),
            .text("starts_at"),
            .text("ends_at"),
            .text("notes"),
            .text("photos_json"),
            .integer("sort_order"),
            .text("created_at"),
            .text("updated_at"),
            .text("deleted_at"),
        ],
        indexes: [
            Index(
                name: "itinerary_items_trip_starts",
                columns: [
                    IndexedColumn.ascending("trip_id"),
                    IndexedColumn.ascending("starts_at"),
                ]
            ),
        ]
    )

    /// Read-only server state. The app never writes either table locally.
    static let tripCreationQuotas = Table(
        name: "trip_creation_quotas",
        columns: [
            .integer("lifetime_count"),
            .text("updated_at"),
        ]
    )

    static let iapEntitlements = Table(
        name: "iap_entitlements",
        columns: [
            .text("product_id"),
            .text("bundle_id"),
            .text("original_transaction_id"),
            .text("transaction_id"),
            .text("status"),
            .text("expires_at"),
            .text("revoked_at"),
            .text("environment"),
            .text("signed_at"),
            .text("verified_at"),
            .text("verification_source"),
            .text("updated_at"),
        ]
    )

    /// Read-only sharing state (see `SharingAppConfiguration`). The server
    /// writes these through the sharing endpoints; each member row's `id` is
    /// `<space>:<user>`.
    static let tripMembers = memberTable("trip_members", spaceColumn: "trip_id")
    static let tripPendingInvites = inviteTable("trip_pending_invites", spaceColumn: "trip_id")
    static let libraryMembers = memberTable("library_members", spaceColumn: "library_id")
    static let libraryPendingInvites = inviteTable("library_pending_invites", spaceColumn: "library_id")

    private static func memberTable(_ name: String, spaceColumn: String) -> Table {
        Table(
            name: name,
            columns: [
                .text(spaceColumn),
                .text("user_id"),
                .text("role"),
                .text("invited_by"),
                .text("joined_at"),
            ],
            indexes: [
                Index(name: "\(name)_space", columns: [IndexedColumn.ascending(spaceColumn)]),
                Index(name: "\(name)_user", columns: [IndexedColumn.ascending("user_id")]),
            ]
        )
    }

    private static func inviteTable(_ name: String, spaceColumn: String) -> Table {
        Table(
            name: name,
            columns: [
                .text(spaceColumn),
                .text("email"),
                .text("role"),
                .text("invited_by"),
                .text("created_at"),
                .text("accepted_at"),
            ],
            indexes: [
                Index(name: "\(name)_space", columns: [IndexedColumn.ascending(spaceColumn)]),
            ]
        )
    }

    /// Device-only ledger used to reserve free allowance while creations are
    /// waiting in PowerSync's upload queue.
    static let pendingTrips = Table(
        name: "pending_trips",
        columns: [
            .text("user_id"),
            .integer("expected_lifetime_count"),
            .text("state"),
            .text("created_at"),
        ],
        localOnly: true
    )

    static let schema = Schema(tables: [
        profiles,
        trips,
        itineraryItems,
        tripCreationQuotas,
        iapEntitlements,
        tripMembers,
        tripPendingInvites,
        libraryMembers,
        libraryPendingInvites,
        pendingTrips,
    ])
}
