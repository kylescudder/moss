import Combine
import Foundation

@MainActor
final class AppServices: ObservableObject {
    static let freeTripCreationLimit = 2

    let auth: AuthClient
    let sync: PowerSyncManager
    let syncIssues: SyncIssueStore
    let billing: BillingRepository
    let trips: TripsRepository
    let itinerary: ItineraryRepository
    let notifications: NotificationManager
    let profile: ProfileRepository

    private var cancellables = Set<AnyCancellable>()

    init() {
        let auth = AuthClient()
        let syncIssues = SyncIssueStore()
        let sync = PowerSyncManager(auth: auth, issues: syncIssues)
        self.auth = auth
        self.sync = sync
        self.syncIssues = syncIssues
        let billing = BillingRepository(auth: auth)
        self.billing = billing
        self.trips = TripsRepository(auth: auth, billing: billing, database: sync.database)
        self.itinerary = ItineraryRepository(database: sync.database)
        self.notifications = NotificationManager.shared
        self.profile = ProfileRepository(database: sync.database)

        for child: any ObservableObject in [auth, sync, syncIssues, billing, trips, itinerary, notifications, profile] {
            (child.objectWillChange as? ObservableObjectPublisher)?
                .sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }

        notifications.bind(auth: auth)
        billing.start()
        Task { await sync.startObservingAuth() }

        auth.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                Task { @MainActor in await self.applyAuth(state: state) }
            }
            .store(in: &cancellables)
    }

    private func applyAuth(state: AuthClient.State) async {
        guard case let .signedIn(userID, _) = state else {
            billing.resetForSignOut()
            trips.reset()
            itinerary.reset()
            profile.reset()
            return
        }
        let id = userID.uuidString.lowercased()
        profile.startWatching(userID: id)
        trips.startWatching(userID: id)
        itinerary.start(userID: id)
        await billing.syncEntitlements()
        await refreshAll()
    }

    func refreshAll() async {
        await profile.refresh()
        await trips.refresh()
        await notifications.registerIfAuthorized()
    }

    func canCreateTrip() async -> TripCreationAvailability {
        if sync.status == .offline { return await localTripAvailability() }
        do {
            let status = try await trips.creationStatus()
            if status.canCreateTrip { return .available }
            if status.subscriptionVerificationPending
                || (billing.hasStoreKitEntitlement && !billing.isSubscribed) {
                return .subscriptionVerificationPending
            }
            return .limitReached
        } catch {
            if case .authenticationRequired = TripsRepository.classifyCreationError(error) {
                return .authenticationRequired
            }
            Log.error(error, category: "trips.creationStatus")
            return await localTripAvailability()
        }
    }

    private func localTripAvailability() async -> TripCreationAvailability {
        do { return try await trips.localCreationStatus().canCreateTrip ? .available : .limitReached }
        catch TripCreationError.quotaSnapshotUnavailable { return .unavailable("Finish the initial sync before saving a trip offline.") }
        catch { return .unavailable("Moss couldn't check your trip allowance. Check your connection and try again.") }
    }
}

enum TripCreationAvailability: Equatable {
    case available
    case limitReached
    case subscriptionVerificationPending
    case authenticationRequired
    case unavailable(String)
}
