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
    /// Who each trip is shared with, and who all of this account's trips are shared with.
    private(set) var tripSharing: SharingRepository
    private(set) var librarySharing: SharingRepository
    /// Invites sent to this account, across one-trip and all-trips sharing.
    private(set) var sharingInbox: SharingInbox
    /// An invite email's link was opened; RootView shows the invites once signed in.
    @Published var showsInvites = false

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
        self.tripSharing = SharingRepository(space: .trip, database: sync.database, auth: auth, owner: sync.accountID)
        self.librarySharing = SharingRepository(space: .library, database: sync.database, auth: auth, owner: sync.accountID)
        self.sharingInbox = SharingInbox([tripSharing, librarySharing])

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
        tripSharing.stopWatching()
        librarySharing.stopWatching()
        billing.resetForSignOut()
        profile = ProfileRepository(database: sync.database)
        trips = TripsRepository(auth: auth, billing: billing, database: sync.database)
        itinerary = ItineraryRepository(database: sync.database)
        tripSharing = SharingRepository(space: .trip, database: sync.database, auth: auth, owner: sync.accountID)
        librarySharing = SharingRepository(space: .library, database: sync.database, auth: auth, owner: sync.accountID)
        sharingInbox = SharingInbox([tripSharing, librarySharing])
        bindAccountPublishers()
        publishWidgetSnapshot()
        objectWillChange.send()
    }

    private func bindAccountPublishers() {
        accountCancellables.removeAll()
        profile.$profile
            .map { $0?.isPremiumAccount == true }
            .removeDuplicates()
            .sink { [weak billing] granted in billing?.setAccessOverride(granted) }
            .store(in: &accountCancellables)
        for child: any ObservableObject in [trips, itinerary, profile, tripSharing, librarySharing] {
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
            tripSharing.stopWatching()
            librarySharing.stopWatching()
            publishWidgetSnapshot()
            return
        }
        let id = userID.uuidString.lowercased()
        profile.startWatching(userID: id)
        trips.startWatching(userID: id)
        itinerary.startWatching(userID: id)
        tripSharing.startWatching(userID: id)
        librarySharing.startWatching(userID: id)
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
        await sharingInbox.refresh()
        if refreshRemoteRegistration {
            await push.refreshRegistration()
        }
    }

    func publishWidgetSnapshot() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let horizon = calendar.date(byAdding: .day, value: WidgetSnapshotStore.itemHorizonDays + 1, to: today) ?? today
        let trips = (trips.currentTrips + trips.upcomingTrips).prefix(20).map {
            WidgetTrip(title: $0.title, destination: $0.destination, startsAt: $0.startsAt, endsAt: $0.endsAt)
        }
        let items = itinerary.items.compactMap { item -> WidgetItem? in
            guard let startsAt = item.startsAt, startsAt >= today, startsAt < horizon else { return nil }
            return WidgetItem(title: item.title, symbol: item.kind.symbol, startsAt: startsAt)
        }
        WidgetSnapshotStore.saveNextTrip(trips: Array(trips), items: Array(items.prefix(100)))
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
