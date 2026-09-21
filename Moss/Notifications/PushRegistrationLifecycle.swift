import Foundation
import UIKit

protocol RemoteNotificationRegistering: Sendable {
    @MainActor
    func registerForRemoteNotifications()
}

struct UIApplicationRemoteNotificationRegistrar: RemoteNotificationRegistering {
    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}

@MainActor
final class PushRegistrationLifecycle {
    private let identityProvider: any PushIdentityProviding
    private let installationIDProvider: any PushInstallationIDProviding
    private let transport: any PushRegistrationTransport
    private let remoteNotifications: any RemoteNotificationRegistering
    private let environment: APNSEnvironment

    private(set) var latestDeviceToken: Data?
    private var identity: PushIdentity?

    init(
        identityProvider: any PushIdentityProviding,
        installationIDProvider: any PushInstallationIDProviding,
        transport: any PushRegistrationTransport,
        remoteNotifications: any RemoteNotificationRegistering,
        environment: APNSEnvironment
    ) {
        self.identityProvider = identityProvider
        self.installationIDProvider = installationIDProvider
        self.transport = transport
        self.remoteNotifications = remoteNotifications
        self.environment = environment
    }

    func activate(authorizationAllowsRemoteRegistration: Bool) async {
        await refreshRegistration(
            authorizationAllowsRemoteRegistration: authorizationAllowsRemoteRegistration
        )
    }

    func receivedDeviceToken(_ data: Data) async {
        latestDeviceToken = data
        await registerLatestTokenIfPossible()
    }

    func refreshRegistration(
        authorizationAllowsRemoteRegistration: Bool
    ) async {
        identity = await identityProvider.currentPushIdentity()
        guard identity != nil else { return }
        await registerLatestTokenIfPossible()
        guard authorizationAllowsRemoteRegistration else { return }
        remoteNotifications.registerForRemoteNotifications()
    }

    func deactivate() async {
        defer { identity = nil }
        guard let identity else { return }

        do {
            try await transport.unregister(
                installationID: installationIDProvider.installationID(),
                identity: identity
            )
        } catch {
            // Session invalidation must continue. A later registration
            // atomically rebinds this installation to the current principal.
            Log.error(error, category: "notifications.unregister")
        }
    }

    func sessionEnded() {
        identity = nil
    }

    private func registerLatestTokenIfPossible() async {
        guard let identity, let latestDeviceToken else { return }
        do {
            try await transport.register(
                installationID: installationIDProvider.installationID(),
                deviceToken: latestDeviceToken,
                environment: environment,
                identity: identity
            )
        } catch {
            Log.error(error, category: "notifications.uploadToken")
        }
    }
}
