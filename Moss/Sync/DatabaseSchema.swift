import PowerSync

enum DatabaseSchema {
    static let profiles = Table(name: "profiles", columns: [
        .text("display_name"), .text("created_at"), .text("updated_at"), .text("deleted_at"),
    ])
    static let trips = Table(name: "trips", columns: [
        .text("owner_id"), .text("title"), .text("destination"), .text("starts_at"),
        .text("ends_at"), .text("notes"), .text("created_at"), .text("updated_at"), .text("deleted_at"),
    ], indexes: [Index(name: "trips_owner_starts", columns: [
        IndexedColumn.ascending("owner_id"), IndexedColumn.ascending("starts_at"),
    ])])
    static let itineraryItems = Table(name: "itinerary_items", columns: [
        .text("trip_id"), .text("owner_id"), .text("kind"), .text("title"), .text("location_name"),
        .text("starts_at"), .text("ends_at"), .text("notes"), .integer("sort_order"),
        .text("created_at"), .text("updated_at"), .text("deleted_at"),
    ], indexes: [Index(name: "itinerary_trip_starts", columns: [
        IndexedColumn.ascending("trip_id"), IndexedColumn.ascending("starts_at"),
    ])])
    /// Membership, quota, and entitlement rows are replicated server state and never locally mutated.
    static let tripMembers = Table(name: "trip_members", columns: [
        .text("trip_id"), .text("user_id"), .text("role"), .text("created_at"),
    ])
    static let tripCreationQuotas = Table(name: "trip_creation_quotas", columns: [
        .integer("lifetime_trip_count"), .text("updated_at"),
    ])
    static let iapEntitlements = Table(name: "iap_entitlements", columns: [
        .text("user_id"), .text("product_id"), .text("bundle_id"), .text("original_transaction_id"),
        .text("transaction_id"), .text("status"), .text("environment"), .text("expires_at"),
        .text("revoked_at"), .text("signed_at"), .text("verified_at"),
        .text("verification_source"), .text("updated_at"),
    ])
    static let pendingTrips = Table(name: "pending_trips", columns: [
        .text("user_id"), .integer("expected_lifetime_count"), .text("state"), .text("created_at"),
    ], localOnly: true)

    static let schema = Schema(tables: [
        profiles, trips, itineraryItems, tripMembers, tripCreationQuotas, iapEntitlements, pendingTrips,
    ])
}
