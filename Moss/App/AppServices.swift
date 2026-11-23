import Combine
import Foundation
import SwiftUI
import WidgetKit

@MainActor
final class AppServices: ObservableObject {
    nonisolated static let freeTripLimit = 2

    let auth: AuthClient
    let sync: PowerSyncManager
    let syncIssues: SyncIssueStore
    let billing: BillingRepository
    private(set) var trips: TripsRepository
    private(set) var itinerary: ItineraryRepository
    let push: PushManager
    private(set) var profile: ProfileRepository

    /// The creation allowance the shared paywall reports.
    var creationQuota: any CreationQuotaProviding { trips }

    private var cancellables = Set<AnyCancellable>()
    private var accountCancellables = Set<AnyCancellable>()

    init(auth: AuthClient = AuthClient(), databaseFilename: String = SyncAppConfiguration.databaseFilename) {
        let syncIssues = SyncIssueStore()
        let sync = PowerSyncManager(auth: auth, issues: syncIssues, databaseFilename: databaseFilename)
        let billing = BillingRepository(auth: auth)
        self.auth = auth
        self.sync = sync
        self.syncIssues = syncIssues
        self.billing = billing
        self.trips = TripsRepository(auth: auth, billing: billing, database: sync.database)
        self.itinerary = ItineraryRepository(database: sync.database)
        self.push = PushManager.shared
        self.profile = ProfileRepository(database: sync.database)

        for child: any ObservableObject in [auth, sync, syncIssues, billing, push] {
            (child.objectWillChange as? ObservableObjectPublisher)?
                .sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }

        push.bind(auth: auth)
        auth.beforeSessionInvalidation = { [weak push] in
            await push?.deactivate()
        }
        auth.afterSessionInvalidationFailure = { [weak push] in
            await push?.activate()
        }
        auth.deleteLocalAccount = { [weak sync] in
            try await sync?.deleteAccountData()
        }
        sync.accountDatabaseDidChange = { [weak self] in await self?.replaceAccountRepositories() }
        bindAccountPublishers()
        billing.start()
        Task { await sync.startObservingAuth() }

        auth.$state.combineLatest(auth.$requiresReauthentication)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .sink { [weak self] state, _ in
                guard let self else { return }
                Task { @MainActor in await self.applyAuth(state: state) }
            }
            .store(in: &cancellables)
    }

    private func replaceAccountRepositories() async {
        profile.stopWatching()
        trips.stopWatching()
        itinerary.stopWatching()
        billing.resetForSignOut()
        profile = ProfileRepository(database: sync.database)
        trips = TripsRepository(auth: auth, billing: billing, database: sync.database)
        itinerary = ItineraryRepository(database: sync.database)
        bindAccountPublishers()
        publishWidgetSnapshot()
        objectWillChange.send()
    }

    private func bindAccountPublishers() {
        accountCancellables.removeAll()
        for child: any ObservableObject in [trips, itinerary, profile] {
            (child.objectWillChange as? ObservableObjectPublisher)?
                .sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &accountCancellables)
        }
        Publishers.CombineLatest(trips.$trips, itinerary.$items)
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _, _ in self?.publishWidgetSnapshot() }
            .store(in: &accountCancellables)
    }

    private func applyAuth(state: AuthClient.State) async {
        guard auth.state == state else { return }
        guard auth.canAccessMainApp, case let .signedIn(userID, _) = state else {
            push.sessionEnded()
            billing.resetForSignOut()
            profile.stopWatching()
            trips.stopWatching()
            itinerary.stopWatching()
            publishWidgetSnapshot()
            return
        }
        let id = userID.uuidString.lowercased()
        profile.startWatching(userID: id)
        trips.startWatching(userID: id)
        itinerary.startWatching(userID: id)
        guard auth.state == state else { return }
        // Install watches before suspension so a later sign-out can stop them.
        await push.activate()
        guard auth.state == state else { return }
        await billing.syncEntitlements()
        await refreshAll(refreshRemoteRegistration: false)
    }

    func refreshAll(refreshRemoteRegistration: Bool = true) async {
        await profile.refresh()
        await trips.refresh()
        await itinerary.refresh()
        if refreshRemoteRegistration {
            await push.refreshRegistration()
        }
    }

    func publishWidgetSnapshot() {
        let next = trips.currentTrips.first ?? trips.upcomingTrips.first
        let todaysItems = itinerary.todaysItems()
        WidgetSnapshotStore.saveNextTrip(
            title: next?.title,
            destination: next?.destination,
            startsAt: next?.startsAt,
            endsAt: next?.endsAt,
            todaysItems: todaysItems.prefix(3).map {
                TodayItemSnapshot(title: $0.title, symbol: $0.kind.symbol, startsAt: $0.startsAt)
            },
            upcomingTripCount: trips.upcomingTrips.count
        )
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotStore.nextTripWidgetKind)
    }

    func canCreateNewTrip() async -> TripCreationAvailability {
        if sync.status == .offline {
            return await localTripCreationAvailability()
        }
        do {
            let status = try await trips.tripCreationStatus()
            return TripCreationAvailability.resolve(
                status: status,
                subscriptionState: billing.subscriptionState
            )
        } catch {
            let classified = TripCreationError.classify(error, subscriptionState: billing.subscriptionState)
            guard classified == .networkFailure || classified == .unknownFailure else {
                return .failed(classified)
            }
            return await localTripCreationAvailability()
        }
    }

    private func localTripCreationAvailability() async -> TripCreationAvailability {
        do {
            let localStatus = try await trips.localTripCreationStatus()
            return TripCreationAvailability.resolve(
                status: localStatus,
                subscriptionState: billing.subscriptionState
            )
        } catch {
            return .failed(TripCreationError.classify(
                error,
                subscriptionState: billing.subscriptionState
            ))
        }
    }
}
