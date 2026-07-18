import Combine
import Foundation

@MainActor
final class AppServices: ObservableObject {
    static let freeTripLimit = 2

    let auth: AuthClient
    let billing: BillingRepository
    let trips: TripsRepository
    let itinerary: ItineraryRepository
    let notifications: NotificationManager
    let profile: ProfileRepository

    private var cancellables = Set<AnyCancellable>()

    init() {
        let auth = AuthClient()
        self.auth = auth
        self.billing = BillingRepository(auth: auth)
        self.trips = TripsRepository(auth: auth)
        self.itinerary = ItineraryRepository(auth: auth)
        self.notifications = NotificationManager.shared
        self.profile = ProfileRepository(auth: auth)

        for child: any ObservableObject in [auth, billing, trips, itinerary, notifications, profile] {
            (child.objectWillChange as? ObservableObjectPublisher)?
                .sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }

        notifications.bind(auth: auth)
        billing.start()

        auth.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                Task { @MainActor in await self.applyAuth(state: state) }
            }
            .store(in: &cancellables)
    }

    private func applyAuth(state: AuthClient.State) async {
        guard case .signedIn = state else {
            billing.resetForSignOut()
            trips.reset()
            itinerary.reset()
            profile.reset()
            return
        }
        await billing.syncEntitlements()
        await refreshAll()
    }

    func refreshAll() async {
        await profile.refresh()
        await trips.refresh()
        await notifications.registerIfAuthorized()
    }

    func canCreateTrip() async -> Bool {
        guard !billing.isSubscribed else { return true }
        return await trips.activeTripCount() < Self.freeTripLimit
    }
}

